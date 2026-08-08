import 'package:shared_preferences/shared_preferences.dart';

/// Where the app-lock on/off flag lives: `shared_preferences`, on this device.
///
/// **Deliberately not the Firestore profile.** The lock is a property of *this
/// phone*, not of the account — turning it on here must not turn it on for the
/// same user's other device, and it must survive being offline. A local
/// dependency is the correct shape for that, not a compromise.
///
/// No secret is kept here and none should ever be. This is a boolean; the real
/// security is the OS keystore behind `local_auth`, which we never see. A user
/// who can flip this key already has a rooted device and full filesystem access,
/// at which point the lock was never the weak link.
abstract interface class AppLockStore {
  Future<bool> isEnabled();
  Future<void> setEnabled(bool value);
}

class SharedPrefsAppLockStore implements AppLockStore {
  const SharedPrefsAppLockStore();

  static const _key = 'app_lock_enabled';

  @override
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    // Default OFF. A lock nobody asked for that they cannot open is worse than
    // no lock, and this is read before the UI exists to explain itself.
    return prefs.getBool(_key) ?? false;
  }

  @override
  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}
