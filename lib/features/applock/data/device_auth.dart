import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// The device's own "prove it's you" prompt, behind an interface so the lock
/// state machine can be tested with no platform channel.
abstract interface class DeviceAuth {
  /// Whether this device can authenticate the user AT ALL — biometrics **or** a
  /// device credential (PIN / pattern / password).
  ///
  /// This is the question that decides whether the lock may be turned on. A
  /// device with no enrolled biometric and no screen lock cannot answer a
  /// prompt, so enabling the lock there would produce a lock that can never be
  /// opened. `isDeviceSupported()` is the right call for it: unlike
  /// `canCheckBiometrics`, it is true when only a PIN exists, which is a
  /// perfectly good second factor and the fallback we deliberately allow.
  Future<bool> canAuthenticate();

  /// Prompt. Returns false on cancel, failure, or any platform error — never
  /// throws, because every caller's answer to "something went wrong" is the
  /// same: stay locked.
  Future<bool> authenticate();
}

class LocalDeviceAuth implements DeviceAuth {
  LocalDeviceAuth([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> canAuthenticate() async {
    try {
      return await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock time-app to see your schedule',
        options: const AuthenticationOptions(
          // FALSE on purpose: this permits the device PIN/pattern/password as a
          // fallback. `biometricOnly: true` would lock out anyone whose
          // fingerprint stops reading — wet hands, a cut, a failed sensor — with
          // no way in at all.
          biometricOnly: false,
          // The OS prompt is a system dialog; when it appears the app is
          // technically backgrounded. This keeps the plugin from tearing down
          // and re-creating state underneath us mid-prompt.
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException {
      // Locked out after too many attempts, no hardware, enrollment removed
      // mid-session — all of them mean the same thing here.
      return false;
    }
  }
}
