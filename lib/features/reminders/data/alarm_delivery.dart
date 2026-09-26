import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Schedules the native alarm-audio trigger independently of notification UI.
///
/// Android and several OEMs are allowed to suppress a full-screen notification
/// launch while the phone is locked. Notification presentation therefore must
/// never be the event that starts the alarm sound. This channel arms a native
/// BroadcastReceiver at the same instant as the notification; that receiver
/// starts the wake-lock-backed AlarmSoundService without waiting for Flutter or
/// an Activity to exist.
class AlarmDelivery {
  const AlarmDelivery();

  static const _channel = MethodChannel('time_app/alarm_delivery');

  Future<String> arm({
    required int id,
    required String itemId,
    required DateTime fireAtUtc,
    required bool exact,
    String headline = '',
    // A voice-note alarm (32c-2): the app-private file and what it must match.
    // The native side re-checks the file at ring time.
    String? voicePath,
    String? voiceSha256,
    int? voiceSizeBytes,
  }) async {
    try {
      return await _channel.invokeMethod<String>('arm', {
            'id': id,
            'itemId': itemId,
            'fireAtMillis': fireAtUtc.millisecondsSinceEpoch,
            'exact': exact,
            // "{planner} planned {task} for you" travels WITH the alarm, so the
            // native heads-up and missed notice need no Dart at fire time.
            'headline': headline,
            'voicePath': ?voicePath,
            'voiceSha256': ?voiceSha256,
            'voiceSizeBytes': ?voiceSizeBytes,
          }) ??
          'unavailable';
    } on MissingPluginException {
      return 'unavailable';
    } on PlatformException catch (e) {
      debugPrint('AlarmDelivery: arm failed — $e');
      return 'platform_error';
    }
  }

  Future<void> cancel(int id) => _invoke('cancel', {'id': id});

  Future<void> cancelAll() => _invoke('cancelAll', const {});

  Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Expected off Android and in unit tests.
    } on PlatformException catch (e) {
      debugPrint('AlarmDelivery: $method failed — $e');
    }
  }
}
