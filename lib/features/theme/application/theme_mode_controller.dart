import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/theme_mode_store.dart';

final themeModeStoreProvider = Provider<ThemeModeStore>((ref) {
  return const SharedPrefsThemeModeStore();
});

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

/// Holds the immediate app appearance and restores the device preference.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  var _changedBeforeRestore = false;

  @override
  ThemeMode build() {
    _restore();
    return ThemeMode.system;
  }

  Future<void> _restore() async {
    final mode = await ref.read(themeModeStoreProvider).read();
    if (!_changedBeforeRestore) state = mode;
  }

  Future<void> setMode(ThemeMode mode) async {
    _changedBeforeRestore = true;
    state = mode;
    await ref.read(themeModeStoreProvider).write(mode);
  }
}
