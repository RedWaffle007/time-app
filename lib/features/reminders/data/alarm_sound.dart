import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The alarm PLAYBACK lifecycle — start the looping tone when the alarm screen
/// appears, stop it on dismiss.
///
/// The sound does NOT live here or in the Dart UI: it lives in the native
/// `AlarmSoundService`, a foreground service holding a wake lock, so it keeps
/// ringing with the screen off, bounded by the native one-minute cap. This is
/// only the switch. `start` also drives the window flags that show the alarm
/// over the lock screen; `stop` clears them.
///
/// A hand-written channel rather than a package, the same call [SecureWindow]
/// makes: the job is two verbs over one native service, and an audio package
/// would not own the wake lock or the foreground-service type this needs.
abstract interface class AlarmSound {
  Future<void> start(String itemId, {String headline = ''});
  Future<void> stop(String itemId);

  /// The sentence the native alarm was delivered with ("{planner} planned {task} for
  /// you"), or null when this process did not receive one.
  Future<String?> headline(String itemId);
}

class PlatformAlarmSound implements AlarmSound {
  const PlatformAlarmSound();

  static const _channel = MethodChannel('time_app/alarm_sound');

  @override
  Future<void> start(String itemId, {String headline = ''}) =>
      _invoke('start', itemId, {'headline': headline});

  @override
  Future<void> stop(String itemId) => _invoke('stop', itemId);

  @override
  Future<String?> headline(String itemId) async {
    try {
      return await _channel.invokeMethod<String>('headline', {
        'itemId': itemId,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('alarm_sound: headline failed — $e');
      return null;
    }
  }

  Future<void> _invoke(
    String method,
    String itemId, [
    Map<String, Object?> extra = const {},
  ]) async {
    try {
      await _channel.invokeMethod<void>(method, {'itemId': itemId, ...extra});
    } on MissingPluginException {
      // iOS / tests register no handler. The alarm still shows; only the
      // wake-lock-backed sound is Android-only.
      debugPrint('alarm_sound: no platform handler ($method)');
    } on PlatformException catch (e) {
      debugPrint('alarm_sound: $method failed — $e');
    }
  }
}
