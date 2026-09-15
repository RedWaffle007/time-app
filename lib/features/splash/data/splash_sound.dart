import 'package:flutter/services.dart';

/// The cold-start pendulum-clock strike — ONE ring ("tunnn"), before the logo.
///
/// Playback, the one-shot, and the mute check all live NATIVELY (see
/// `SplashSound.kt` on the `time_app/splash_sound` channel). Dart just fires it
/// once, as the black reveal mounts.
class SplashSound {
  const SplashSound._();
  static const instance = SplashSound._();

  /// The platform channel the native one-shot listens on. Exposed so a test can
  /// install a mock handler and assert the strike fires as the reveal mounts.
  static const channelName = 'time_app/splash_sound';
  static const _channel = MethodChannel(channelName);

  /// Ring once. Native stays silent if the ringer is not NORMAL. Fire-and-forget
  /// — a missing implementation (iOS, or a platform without the channel) is a
  /// silent no-op, never an error that could disturb launch.
  Future<void> play() async {
    try {
      await _channel.invokeMethod('play');
    } catch (_) {
      // No sound is never worth failing a launch over.
    }
  }
}
