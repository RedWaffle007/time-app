import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'model_manifest.dart';

/// Why a file on this device is not usable.
enum ModelFileProblem {
  /// Nothing at that path.
  missing,

  /// Present, but not the length the manifest expects.
  wrongSize,

  /// Right length, wrong bytes.
  wrongChecksum,
}

/// The model files on disk: where they live, whether they are intact, and the
/// one operation that promotes a download to a real file.
///
/// **Storage is app-private support, not documents.** These are machine
/// artifacts, not the user's content: nothing should surface them in a file
/// picker, and on iOS the support directory is the one that is excluded from
/// iCloud backup by default. Backing up 143MB of re-downloadable weights would
/// be a straightforward abuse of someone's iCloud quota.
///
/// **The `.part` discipline is the whole safety story.** A download writes to
/// `<name>.part` and is renamed to `<name>` only after it verifies. A rename
/// inside one directory is atomic, so a file bearing the real name is *by
/// construction* a file that passed — [isReady] can trust the filesystem
/// instead of keeping a side-table of "which downloads finished", which is
/// exactly the bookkeeping that goes stale after a crash.
class ModelStore {
  /// [supportDirectory] is injectable so this is testable without the
  /// `path_provider` platform channel — the verification logic below is the
  /// part most worth testing and it has nothing to do with which directory it
  /// runs in.
  ///
  /// [files] defaults to the real manifest and is injectable for the same
  /// reason: now that the manifest carries real digests, a test cannot satisfy
  /// it without shipping 143MB of fixtures. Overriding it lets the download and
  /// state-machine tests run the **strict** verification path against small
  /// files, which is the path that actually ships.
  ModelStore({
    Future<Directory> Function()? supportDirectory,
    this.files = kModelFiles,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  /// The manifest this store answers for. [ModelSetupController] iterates this
  /// rather than the constant, so the two can never disagree about which files
  /// [isReady] was asking about.
  final List<ModelFile> files;

  /// Its own subdirectory, so [deleteAll] can be a directory delete and can
  /// never take anything else with it.
  static const _folder = 'chatbot_model';

  /// Suffix for a download in flight. Deliberately not a hidden file: on
  /// Android there is nothing to hide it from, and a visible suffix is what
  /// makes a stuck state obvious when someone dumps the app directory.
  static const partSuffix = '.part';

  Directory? _cached;

  /// The model directory, created if absent.
  Future<Directory> directory() async {
    final cached = _cached;
    if (cached != null) return cached;
    final support = await _supportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}$_folder');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return _cached = dir;
  }

  /// The final resting place of [file].
  Future<File> fileFor(ModelFile file) async =>
      File('${(await directory()).path}${Platform.pathSeparator}${file.name}');

  /// Where [file] is written while it downloads.
  Future<File> partFileFor(ModelFile file) async => File(
      '${(await directory()).path}${Platform.pathSeparator}${file.name}$partSuffix');

  /// How many bytes of [file] are already on disk from an interrupted attempt.
  /// Zero when there is no partial download — which is also what a retry after
  /// a corrupt-file failure sees, because that path deletes the part first.
  Future<int> partialBytes(ModelFile file) async {
    final part = await partFileFor(file);
    if (!part.existsSync()) return 0;
    return part.length();
  }

  /// Check an **installed** file. Null means it is good.
  Future<ModelFileProblem?> verify(ModelFile file) async =>
      verifyAt(await fileFor(file), file);

  /// Check an arbitrary path against [expected]'s constraints.
  ///
  /// Used on the `.part` file before the rename — verifying the destination
  /// after installing would mean a corrupt file had already been installed, and
  /// the point of the `.part` discipline is that it never is.
  ///
  /// A null `sha256`/`sizeBytes` in the manifest is a **skip, not a pass**: the
  /// caller still checks that the byte count matched what the server declared.
  /// See [ModelFile.isPlaceholder].
  Future<ModelFileProblem?> verifyAt(File actual, ModelFile expected) async {
    if (!actual.existsSync()) return ModelFileProblem.missing;

    final expectedSize = expected.sizeBytes;
    if (expectedSize != null && await actual.length() != expectedSize) {
      return ModelFileProblem.wrongSize;
    }

    final expectedHash = expected.sha256;
    if (expectedHash != null) {
      final actualHash = await sha256OfFile(actual);
      // Case-insensitive: a digest pasted out of `shasum` and one pasted out of
      // a GitHub UI can differ only in case, and that is not a corrupt file.
      if (actualHash.toLowerCase() != expectedHash.toLowerCase()) {
        return ModelFileProblem.wrongChecksum;
      }
    }

    return null;
  }

  /// True when every file in the manifest is present and verifies.
  ///
  /// This is the first-launch question — "do I need to download anything?" — and
  /// it deliberately re-verifies rather than merely checking existence. Storage
  /// on a phone gets truncated by low-space reclamation and by a kill during a
  /// rename; existence alone would send a corrupt model into an inference
  /// engine, where the failure is unreadable.
  Future<bool> isReady() async {
    for (final file in files) {
      if (await verify(file) != null) return false;
    }
    return true;
  }

  /// Promote a verified `.part` to its real name, replacing any existing file.
  ///
  /// Atomic within the directory, which is what lets [isReady] trust a name.
  Future<void> install(ModelFile file) async {
    final part = await partFileFor(file);
    final destination = await fileFor(file);
    if (destination.existsSync()) await destination.delete();
    await part.rename(destination.path);
  }

  /// Throw away a partial download, so the next attempt starts clean. Called
  /// when the server ignored `Range` or the bytes did not verify — in both
  /// cases resuming would append to something untrustworthy.
  Future<void> discardPartial(ModelFile file) async {
    final part = await partFileFor(file);
    if (part.existsSync()) await part.delete();
  }

  /// Remove everything, partial or installed. Not wired to any UI in Part 1;
  /// it exists because "re-download from scratch" is the only recovery for a
  /// model that verifies but behaves wrongly, and the engine lands next.
  Future<void> deleteAll() async {
    final dir = await directory();
    if (dir.existsSync()) await dir.delete(recursive: true);
    _cached = null;
  }

  /// Streamed sha256 — the file is up to 130MB and must never be read into
  /// memory to hash it.
  static Future<String> sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
