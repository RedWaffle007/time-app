import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's `FLAG_SECURE` — blocks screenshots and blanks the app's thumbnail
/// in the recents switcher.
///
/// **Tied to the app-lock toggle, not a switch of its own.** "Hide my content"
/// is one intent; two switches would make people reason about a distinction they
/// should not have to hold. Accepted cost, stated plainly: with the lock on you
/// cannot screenshot your own schedule.
///
/// A hand-written method channel rather than a package: the job is one boolean
/// and one `Window` call, and the available packages for it are unmaintained
/// against current Android.
abstract interface class SecureWindow {
  Future<void> setSecure(bool value);
}

class PlatformSecureWindow implements SecureWindow {
  const PlatformSecureWindow();

  static const _channel = MethodChannel('time_app/secure_window');

  @override
  Future<void> setSecure(bool value) async {
    try {
      await _channel.invokeMethod<void>('setSecure', value);
    } on MissingPluginException {
      // iOS has no FLAG_SECURE equivalent and no handler is registered there.
      // The lock itself still works; only the recents-blanking is Android-only.
      debugPrint('secure_window: no platform handler (expected off Android)');
    } on PlatformException catch (e) {
      debugPrint('secure_window: failed to set $value — $e');
    }
  }
}
