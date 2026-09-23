import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Identifies one physical installation. Android's first-install timestamp is
/// preserved across an in-place update but changes after uninstall/reinstall,
/// unlike SharedPreferences, which Android Auto Backup may restore.
abstract interface class InstallIdentity {
  Future<String> current();
}

class MethodChannelInstallIdentity implements InstallIdentity {
  const MethodChannelInstallIdentity();

  static const channelName = 'time_app/install_identity';
  static const _channel = MethodChannel(channelName);

  @override
  Future<String> current() async {
    try {
      return await _channel.invokeMethod<String>('current') ??
          'platform-unavailable';
    } catch (error) {
      // Android registers this before Dart starts. The fallback keeps other
      // platforms usable without pretending to distinguish their installs.
      debugPrint('InstallIdentity: read failed: $error');
      return 'platform-unavailable';
    }
  }
}

/// Remembers that the first-run permission flow has been SHOWN, on this device.
///
/// Deliberately a device concern, not a Firestore/profile one, exactly like the
/// app-lock flag: onboarding is about THIS phone's OS permissions, and a second
/// device signed into the same account has its own permissions to grant.
///
/// Completion is tied to [InstallIdentity], not stored as a bare bool. Android
/// can restore SharedPreferences from an old installation while resetting its
/// runtime permissions; accepting that restored bool made a reinstall skip the
/// permission flow entirely. Grant state itself is still read live from the OS.
abstract interface class OnboardingStore {
  Future<bool> isCompleted();
  Future<void> markCompleted();

  /// Clears completion so the debug reset affordance can re-run the flow.
  Future<void> reset();
}

class SharedPrefsOnboardingStore implements OnboardingStore {
  const SharedPrefsOnboardingStore()
      : _installIdentity = const MethodChannelInstallIdentity();

  @visibleForTesting
  const SharedPrefsOnboardingStore.withInstallIdentity(this._installIdentity);

  final InstallIdentity _installIdentity;

  // Versioned key: if the set of onboarding steps ever changes materially, bump
  // the suffix to re-show the flow rather than silently leaving old users behind
  // a permission that did not exist when they onboarded.
  static const _key = 'onboarding_permissions_completed_install_v2';

  @override
  Future<bool> isCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    final currentInstall = await _installIdentity.current();
    return prefs.getString(_key) == currentInstall;
  }

  @override
  Future<void> markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, await _installIdentity.current());
  }

  @override
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
