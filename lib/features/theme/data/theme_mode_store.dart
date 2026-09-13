import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists this device's explicit appearance preference.
abstract interface class ThemeModeStore {
  Future<ThemeMode> read();
  Future<void> write(ThemeMode mode);
}

class SharedPrefsThemeModeStore implements ThemeModeStore {
  const SharedPrefsThemeModeStore();

  static const _key = 'theme_mode_v1';

  @override
  Future<ThemeMode> read() async {
    final prefs = await SharedPreferences.getInstance();
    return switch (prefs.getString(_key)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  @override
  Future<void> write(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}
