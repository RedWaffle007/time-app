import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/walkthrough_store.dart';

/// Where the "tour shown" flag lives. See [WalkthroughStore].
final walkthroughStoreProvider = Provider<WalkthroughStore>((ref) {
  return const SharedPrefsWalkthroughStore();
});

/// Whether the orientation tour has already been shown on this device.
///
/// A plain [FutureProvider] read of the store. [markWalkthroughCompleted]
/// re-reads it after writing, so `HomeShell` — which watches this — will not
/// re-trigger the first-run tour once it resolves true.
final walkthroughCompletedProvider = FutureProvider<bool>((ref) async {
  return ref.watch(walkthroughStoreProvider).isCompleted();
});

/// The **replay trigger** — a monotonically increasing nonce, bumped by the
/// "How this app works" entry in the You hub.
///
/// Replay deliberately does NOT clear [walkthroughCompletedProvider]: that flag
/// governs the *uninvited* first-run appearance only. `HomeShell` listens to
/// this and shows the tour on any change, so replaying is orthogonal to whether
/// the tour has ever auto-shown. A nonce (not a bool) so two replays in a row
/// each register as a change. A plain [Notifier] rather than the legacy
/// `StateProvider`, which Riverpod 3 no longer exports by default.
final walkthroughTriggerProvider =
    NotifierProvider<WalkthroughTrigger, int>(WalkthroughTrigger.new);

class WalkthroughTrigger extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Bump the replay trigger — the one call the You-hub tile makes.
void replayWalkthrough(WidgetRef ref) {
  ref.read(walkthroughTriggerProvider.notifier).bump();
}

/// Mark the tour done and refresh the flag so `HomeShell` stops auto-showing it.
/// One helper so both the first-run finish and a replay finish flip the flag the
/// same way. Idempotent — a replay after completion writes `true` over `true`.
Future<void> markWalkthroughCompleted(WidgetRef ref) async {
  await ref.read(walkthroughStoreProvider).markCompleted();
  ref.invalidate(walkthroughCompletedProvider);
}
