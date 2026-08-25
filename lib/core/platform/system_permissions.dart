import 'package:flutter/services.dart';

/// The battery-exemption and OEM-autostart surface — the two permissions the
/// `flutter_local_notifications` plugin does NOT cover, spoken to over the
/// native channels [MainActivity] registers (`time_app/battery`,
/// `time_app/autostart`).
///
/// Kept behind an interface for the same reason the reminder scheduler is: it
/// lets onboarding's tests use a fake and never touch a platform channel. **No
/// method here throws** — every call degrades to a safe answer, because a
/// permission surface that can throw would take down the onboarding flow that
/// drives it, and a locked-down OEM that refuses an intent is a normal state,
/// not an error.
abstract interface class SystemPermissions {
  /// Whether the app is exempt from battery optimizations (Doze). True on
  /// failure / off-Android — "no restriction we can see" — so the battery step
  /// is skipped rather than shown against a surface that cannot answer.
  Future<bool> isBatteryUnrestricted();

  /// Fire the direct battery-exemption dialog (falling back to the list). Returns
  /// whether anything could be launched.
  Future<bool> requestBatteryExemption();

  /// Whether a launchable OEM autostart screen exists on this device. False on
  /// failure — onboarding then shows the guided card with no deep-link button.
  Future<bool> canOpenAutostartSettings();

  /// Launch the OEM autostart screen (resolve-checked natively). Returns whether
  /// a screen actually opened.
  Future<bool> openAutostartSettings();
}

/// The real implementation, over the two [MethodChannel]s.
class MethodChannelSystemPermissions implements SystemPermissions {
  const MethodChannelSystemPermissions();

  static const _battery = MethodChannel('time_app/battery');
  static const _autostart = MethodChannel('time_app/autostart');

  @override
  Future<bool> isBatteryUnrestricted() =>
      _invoke(_battery, 'isIgnoring', onError: true);

  @override
  Future<bool> requestBatteryExemption() =>
      _invoke(_battery, 'request', onError: false);

  @override
  Future<bool> canOpenAutostartSettings() =>
      _invoke(_autostart, 'canOpen', onError: false);

  @override
  Future<bool> openAutostartSettings() =>
      _invoke(_autostart, 'open', onError: false);

  /// One place for the try/catch discipline: a missing handler (a test binding,
  /// an old build, a non-Android platform) is a `MissingPluginException`, and the
  /// right answer to "can we?" there is the caller's stated [onError] default —
  /// never a thrown error into the widget tree.
  Future<bool> _invoke(
    MethodChannel channel,
    String method, {
    required bool onError,
  }) async {
    try {
      return await channel.invokeMethod<bool>(method) ?? onError;
    } catch (_) {
      return onError;
    }
  }
}
