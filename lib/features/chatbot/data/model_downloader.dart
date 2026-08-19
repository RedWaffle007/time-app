import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'model_manifest.dart';
import 'model_store.dart';

/// Acquiring the model failed, phrased for the person holding the phone.
///
/// Deliberately **not** `ChatbotFailure`. That type is the seam's promise about
/// a conversational *turn*; a download is not a turn, and folding the two would
/// let a network error surface inside a transcript as if the bot had said
/// something. Same discipline, separate concept.
class ModelDownloadFailure implements Exception {
  const ModelDownloadFailure(this.message);

  /// A sentence with a next step in it, rendered verbatim by the setup screen.
  final String message;

  @override
  String toString() => 'ModelDownloadFailure: $message';
}

/// Progress within the file currently downloading.
///
/// [total] is null when the server declared no length — the UI then shows an
/// indeterminate indicator rather than inventing a percentage (UI-RULES.md
/// §6.7).
typedef DownloadProgress = void Function(int received, int? total);

/// Fetches the model files, resumably, and installs only what verifies.
///
/// Everything network-shaped in the on-device path lives here. The engine that
/// lands in Part 2 consumes files from [ModelStore] and never learns that a
/// download existed.
class ModelDownloader {
  ModelDownloader(this._store, {http.Client? client})
      : _client = client ?? http.Client();

  final ModelStore _store;
  final http.Client _client;

  /// Time allowed to *start* getting a response. A wrong URL or a dead network
  /// usually fails faster than this; the budget is for the case that hangs.
  static const _connectTimeout = Duration(seconds: 30);

  /// Time allowed **between chunks**, not for the whole download.
  ///
  /// A 130MB file has no sane total budget — on a slow connection a legitimate
  /// download takes many minutes — but 30 seconds with no bytes arriving is a
  /// dead socket on any connection speed. This is the timeout that actually
  /// distinguishes "slow" from "stopped".
  static const _idleTimeout = Duration(seconds: 30);

  /// How often [onProgress] may fire. A 130MB download delivers tens of
  /// thousands of chunks; forwarding each one would rebuild the screen far
  /// faster than it can paint, and the bar would move no more smoothly.
  static const _progressInterval = Duration(milliseconds: 100);

  /// Download [file] if it is not already installed and intact, then install it.
  ///
  /// Returns without touching the network when the file already verifies, which
  /// is what makes "files already present → skip straight to ready" free rather
  /// than a special case in the caller.
  ///
  /// Throws [ModelDownloadFailure] — and nothing else — on any failure.
  Future<void> ensure(
    ModelFile file, {
    required DownloadProgress onProgress,
    void Function()? onVerifying,
  }) async {
    if (await _store.verify(file) == null) return;

    // An installed-but-broken file is never left in place: it would keep
    // failing `isReady` forever while the fresh download sat beside it under a
    // `.part` name that nothing reads.
    final existing = await _store.fileFor(file);
    if (existing.existsSync()) await existing.delete();

    await _download(file, onProgress: onProgress);

    // Announced before the hashing starts, not after: sha256 over 130MB takes
    // long enough on a phone that a full-but-frozen progress bar reads as a
    // hang. Only the layer doing the hashing knows when it begins.
    onVerifying?.call();

    final part = await _store.partFileFor(file);
    final problem = await _store.verifyAt(part, file);
    if (problem != null) {
      // The bytes on disk are known-bad, so resuming from them next time would
      // append good bytes to bad ones forever. Start clean.
      await _store.discardPartial(file);
      throw ModelDownloadFailure(_corrupt(file, problem));
    }

    await _store.install(file);
  }

  Future<void> _download(
    ModelFile file, {
    required DownloadProgress onProgress,
  }) async {
    final alreadyHave = await _store.partialBytes(file);

    final request = http.Request('GET', Uri.parse(file.url));
    if (alreadyHave > 0) {
      request.headers['Range'] = 'bytes=$alreadyHave-';
    }

    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_connectTimeout);
    } on TimeoutException {
      throw ModelDownloadFailure(
        "The download didn't start in time. Check your connection and try "
        'again — anything already downloaded is kept.',
      );
    } on SocketException {
      throw const ModelDownloadFailure(_offline);
    } on http.ClientException {
      // What a refused or dropped connection surfaces as on Android, where the
      // underlying SocketException is wrapped rather than rethrown.
      throw const ModelDownloadFailure(_offline);
    }

    // **The response code decides whether this is a resume — never the request.**
    //
    // A server that ignores `Range` answers 200 with the WHOLE body. Appending
    // that to a partial file produces a corrupt file of plausible size: exactly
    // what the checksum exists to catch, but far better not to create. So:
    //   206 → the server honoured the range, append
    //   200 → it did not, truncate and start over
    //   416 → our part is at or past the full length, so it is junk; start over
    final bool resuming;
    switch (response.statusCode) {
      case 206:
        resuming = true;
      case 200:
        resuming = false;
        await _store.discardPartial(file);
      case 416:
        await _store.discardPartial(file);
        throw ModelDownloadFailure(
          'The half-finished download of ${file.description} no longer matches '
          "what's on the server. Tap Try again to start it fresh.",
        );
      case 404:
        throw ModelDownloadFailure(
          "${file.description} isn't at the download address this build was "
          'made with. The app needs an update.',
        );
      default:
        throw ModelDownloadFailure(
          'The download server answered ${response.statusCode}. '
          'Try again in a moment.',
        );
    }

    final startedAt = resuming ? alreadyHave : 0;
    // `contentLength` on a 206 is the length of the RANGE, not of the file, so
    // the total is what we already have plus what is coming.
    final declared = response.contentLength;
    final total = declared == null ? null : startedAt + declared;

    final part = await _store.partFileFor(file);
    final sink = part.openWrite(
      mode: resuming ? FileMode.writeOnlyAppend : FileMode.writeOnly,
    );

    var received = startedAt;
    var lastReport = DateTime.now();
    onProgress(received, total);

    try {
      await for (final chunk in response.stream.timeout(_idleTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReport) >= _progressInterval) {
          lastReport = now;
          onProgress(received, total);
        }
      }
      await sink.flush();
    } on TimeoutException {
      await sink.close();
      throw ModelDownloadFailure(
        'The download stalled while fetching ${file.description}. Tap Try '
        'again — it picks up where it left off.',
      );
    } on SocketException {
      await sink.close();
      throw const ModelDownloadFailure(_interrupted);
    } on http.ClientException {
      await sink.close();
      throw const ModelDownloadFailure(_interrupted);
    } finally {
      // Safe to call twice; the catch blocks above close early so the partial
      // bytes are on disk before the failure propagates and the screen offers
      // a resume.
      await sink.close();
    }

    onProgress(received, total);

    // A truncated stream that ended cleanly is the one failure a checksum would
    // catch only after hashing 130MB. Catching it here also keeps the `.part`
    // file, so the retry resumes instead of restarting.
    if (total != null && received != total) {
      throw ModelDownloadFailure(
        'The connection dropped partway through ${file.description}. Tap Try '
        'again — it picks up where it left off.',
      );
    }
  }

  String _corrupt(ModelFile file, ModelFileProblem problem) => switch (problem) {
        ModelFileProblem.missing =>
          'The download of ${file.description} left nothing on the device. '
              'Check you have free storage, then try again.',
        // Both of these mean the same thing to the user, and saying "checksum"
        // to them would explain nothing they can act on.
        ModelFileProblem.wrongSize || ModelFileProblem.wrongChecksum =>
          '${file.description} downloaded but arrived damaged. It has been '
              'discarded — tap Try again to download it fresh.',
      };

  static const _offline =
      "Couldn't reach the download server. Check your internet connection and "
      'try again.';

  static const _interrupted =
      'The connection dropped during the download. Tap Try again — it picks up '
      'where it left off.';

  /// Closes the connection pool. Registered on the provider's `onDispose`, the
  /// same way `HttpChatbotService.dispose` is.
  void dispose() => _client.close();
}
