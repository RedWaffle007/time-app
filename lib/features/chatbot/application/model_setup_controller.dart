import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/model_downloader.dart';
import '../data/model_manifest.dart';
import '../data/model_store.dart';
import '../domain/model_setup_state.dart';

/// Plain providers, no families or code-gen — same shape as the rest of the
/// app's Riverpod use.

final chatbotModelStoreProvider = Provider<ModelStore>((ref) => ModelStore());

final chatbotModelDownloaderProvider = Provider<ModelDownloader>((ref) {
  final downloader = ModelDownloader(ref.watch(chatbotModelStoreProvider));
  ref.onDispose(downloader.dispose);
  return downloader;
});

/// Drives acquisition of the on-device model: check what is there, download
/// what is not, verify, report.
///
/// **Not `autoDispose`, deliberately.** A 130MB download must survive the user
/// leaving the screen — backing out of it to check something should not throw
/// away twenty minutes of transfer. The download keeps running and the screen
/// re-attaches to the same state when reopened.
///
/// (Even if it were cancelled, nothing would be lost: the `.part` file makes the
/// next attempt a resume. Surviving is about not making the user wait twice,
/// not about correctness.)
final modelSetupControllerProvider =
    NotifierProvider<ModelSetupController, ModelSetupState>(
        ModelSetupController.new);

class ModelSetupController extends Notifier<ModelSetupState> {
  /// The run currently in flight, or null.
  ///
  /// Two runs at once would put two writers on the same `.part` file, so a
  /// second `start()` **joins** the first rather than beginning another: the
  /// user tapping Try again twice means "keep going", not "download it twice",
  /// and a caller that awaits gets the real completion either way.
  Future<void>? _run;

  @override
  ModelSetupState build() {
    // The **check** starts itself; the download does not. Every entry point
    // wants "is the model here?" answered immediately, and leaving that to each
    // screen is how one of them ends up not asking. Deferred by a microtask so
    // `build` returns its initial state before anything can write a new one.
    Future.microtask(check);
    return const ModelChecking();
  }

  /// Answer "is the model already here?" and nothing more.
  ///
  /// **Touches no network.** It ends at either [ModelReady] or [ModelNeeded],
  /// and [ModelNeeded] is where it stays until someone taps Download: 143MB is
  /// not a thing to start on a person's behalf because they opened a screen.
  ///
  /// A download already in flight is left alone — re-checking the disk under a
  /// running download would report `ModelNeeded` over live progress.
  Future<void> check() async {
    if (_run != null) return;
    if (!ref.mounted) return;
    state = const ModelChecking();

    try {
      final ready = await ref.read(chatbotModelStoreProvider).isReady();
      if (!ref.mounted) return;
      state = ready ? const ModelReady() : ModelNeeded(kModelTotalBytes);
    } catch (_) {
      // Reading the app's own directory failing is not something to explain in
      // storage terms; offering the download is the useful next step either way.
      if (ref.mounted) state = ModelNeeded(kModelTotalBytes);
    }
  }

  /// Download whatever is missing and bring the model to [ModelReady].
  ///
  /// Both the Download action and the Retry one: a failed run left either a
  /// resumable `.part` or a clean slate, so re-running is always the right
  /// recovery and there is no second path to keep in step with this one.
  Future<void> start() =>
      _run ??= _perform().whenComplete(() => _run = null);

  Future<void> _perform() async {
    // Every `state =` below is guarded by `ref.mounted`. A 130MB download
    // outlives plenty of things: without the guard, a container torn down
    // mid-run (app teardown, or a test) takes a "Cannot use Ref after it has
    // been disposed" throw out of a callback nobody is awaiting.
    if (!ref.mounted) return;
    state = const ModelChecking();

    final store = ref.read(chatbotModelStoreProvider);
    final downloader = ref.read(chatbotModelDownloaderProvider);

    try {
      if (await store.isReady()) {
        if (ref.mounted) state = const ModelReady();
        return;
      }

      // `store.files`, not the constant: `isReady` above answered for this
      // exact list, and two sources for "which files" is how a store that says
      // ready and a loop that downloads a fifth file come apart.
      final files = store.files;
      for (var i = 0; i < files.length; i++) {
        final file = files[i];

        // Skip what is already good, silently — a resumed session should not
        // replay three finished files as flickering progress.
        if (await store.verify(file) == null) continue;

        await downloader.ensure(
          file,
          onProgress: (received, total) {
            if (!ref.mounted) return;
            state = ModelDownloading(
              file: file,
              fileNumber: i + 1,
              fileCount: files.length,
              received: received,
              total: total,
            );
          },
          onVerifying: () {
            if (!ref.mounted) return;
            state = ModelVerifying(file);
          },
        );
      }

      if (ref.mounted) state = const ModelReady();
    } on ModelDownloadFailure catch (failure) {
      if (!ref.mounted) return;
      // The downloader promises this is the only thing it throws and that its
      // message is already written for a person. Rendering it verbatim is what
      // makes a dropped connection read as "tap Try again" instead of as a
      // crash.
      state = ModelFailed(failure.message);
    } catch (_) {
      // Anything else is a bug or a filesystem refusal — out of storage is the
      // realistic one. The user still gets a sentence they can act on.
      if (!ref.mounted) return;
      state = ModelFailed(
        "Setting up the offline model didn't finish. Check you have enough "
        'free storage, then try again.',
      );
    }
  }
}
