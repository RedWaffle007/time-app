import 'package:shared_preferences/shared_preferences.dart';

/// Remembers that the first-run **orientation walkthrough** (the coach-mark tour
/// of the five-pillar bar) has been shown, on THIS device.
///
/// Deliberately a device concern, not a Firestore/profile one — the same
/// reasoning as [OnboardingStore] (`onboarding_store.dart`): the tour orients
/// someone to the UI in front of them, and a second device signed into the same
/// account has its own first sitting. It records only "the tour was completed or
/// skipped", nothing per-step. Replaying it later never touches this flag (see
/// `walkthrough_providers.dart` → the trigger), so the flag means exactly
/// "should the tour appear UNINVITED on launch", and only that.
abstract interface class WalkthroughStore {
  Future<bool> isCompleted();
  Future<void> markCompleted();

  /// Clears the flag so the tour shows again on next launch. Not wired to any UI
  /// today — replay goes through the trigger, which does not reset this.
  Future<void> reset();
}

class SharedPrefsWalkthroughStore implements WalkthroughStore {
  const SharedPrefsWalkthroughStore();

  // Versioned key, same discipline as onboarding: if the set of pillars the
  // tour covers changes materially, bump the suffix to re-show it rather than
  // leaving existing users oriented to a bar that no longer exists.
  static const _key = 'walkthrough_completed_v1';

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
