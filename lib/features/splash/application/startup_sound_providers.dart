import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/startup_sound_store.dart';

/// Read in `main()` BEFORE runApp and overridden there: the strike plays as
/// the very first frame mounts, before any async read could finish. Defaults
/// to ON when not overridden (tests, or a failed read) — the shipped behaviour.
final startupSoundInitiallyEnabledProvider = Provider<bool>((ref) => true);

final startupSoundStoreProvider = Provider<StartupSoundStore>((ref) {
  return const SharedPrefsStartupSoundStore();
});

/// The live toggle. Only the startup screen's strike reads it — alarm audio
/// (AlarmSoundService) is never affected.
final startupSoundEnabledProvider =
    NotifierProvider<StartupSoundController, bool>(StartupSoundController.new);

class StartupSoundController extends Notifier<bool> {
  @override
  bool build() => ref.watch(startupSoundInitiallyEnabledProvider);

  /// Applies at once in the UI; persisted for the next cold start. A failed
  /// write reverts, so the switch never shows a setting that did not stick.
  Future<void> setEnabled(bool value) async {
    final previous = state;
    state = value;
    try {
      await ref.read(startupSoundStoreProvider).setEnabled(value);
    } catch (_) {
      state = previous;
    }
  }
}
