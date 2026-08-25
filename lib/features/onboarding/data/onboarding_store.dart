import 'package:shared_preferences/shared_preferences.dart';

/// Remembers that the first-run permission flow has been SHOWN, on this device.
///
/// Deliberately a device concern, not a Firestore/profile one, exactly like the
/// app-lock flag: onboarding is about THIS phone's OS permissions, and a second
/// device signed into the same account has its own permissions to grant.
///
/// It records only "the flow was completed", never per-step grant state. Grant
/// state is read live from the OS every time ([ReminderPermissionState]) — the
/// authority — so caching it here would be a second source that drifts the
/// moment the user changes a toggle in Settings. This flag exists solely to stop
/// the gate re-showing the flow forever on an aggressive OEM, where the
/// autostart step can never be confirmed granted.
abstract interface class OnboardingStore {
  Future<bool> isCompleted();
  Future<void> markCompleted();

  /// Clears the flag so the flow shows again — for a "reset onboarding" affordance
  /// if one is ever added. Not wired to any UI today.
  Future<void> reset();
}

class SharedPrefsOnboardingStore implements OnboardingStore {
  const SharedPrefsOnboardingStore();

  // Versioned key: if the set of onboarding steps ever changes materially, bump
  // the suffix to re-show the flow rather than silently leaving old users behind
  // a permission that did not exist when they onboarded.
  static const _key = 'onboarding_permissions_completed_v1';

  @override
  Future<bool> isCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  @override
  Future<void> markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }

  @override
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
