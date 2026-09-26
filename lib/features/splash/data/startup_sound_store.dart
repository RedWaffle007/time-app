import 'package:shared_preferences/shared_preferences.dart';

/// Whether the startup screen plays its clock strike, on THIS device.
///
/// Device-local like the app lock: a sound preference belongs to the phone in
/// your hand, not to the account. Default ON (the shipped behaviour).
abstract interface class StartupSoundStore {
  Future<bool> isEnabled();
  Future<void> setEnabled(bool value);
}

class SharedPrefsStartupSoundStore implements StartupSoundStore {
  const SharedPrefsStartupSoundStore();

  static const key = 'startup_sound_enabled';

  @override
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? true;
  }

  @override
  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }
}
