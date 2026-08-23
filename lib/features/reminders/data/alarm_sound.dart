import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The alarm PLAYBACK lifecycle — start the looping tone when the alarm screen
/// appears, stop it on dismiss.
///
/// The sound does NOT live here or in the Dart UI: it lives in the native
/// `AlarmSoundService`, a foreground service holding a wake lock, so it keeps
/// ringing with the screen off. This is only the switch. `start` also drives the
/// window flags that show the alarm over the lock screen; `stop` clears them.
///
/// A hand-written channel rather than a package, the same call [SecureWindow]
/// makes: the job is two verbs over one native service, and an audio package
/// would not own the wake lock or the foreground-service type this needs.
abstract interface class AlarmSound {
  Future<void> start();
  Future<void> stop();
}

class PlatformAlarmSound implements AlarmSound {
  const PlatformAlarmSound();

  static const _channel = MethodChannel('time_app/alarm_sound');

  @override
  Future<void> start() => _invoke('start');

  @override
  Future<void> stop() => _invoke('stop');

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // iOS / tests register no handler. The alarm still shows; only the
      // wake-lock-backed sound is Android-only.
      debugPrint('alarm_sound: no platform handler ($method)');
    } on PlatformException catch (e) {
      debugPrint('alarm_sound: $method failed — $e');
    }
  }
}
