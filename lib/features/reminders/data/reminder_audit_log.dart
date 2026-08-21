import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart's end of the fire-timing audit — the instrument carried over from
/// `spikes/alarm_spike/`.
///
/// **Dart never records a fire.** It arms, cancels, annotates and reads. The one
/// row that matters — `FIRED`, with the delay and the device's Doze / power-save
/// / battery-optimisation / screen state at that instant — is written by a plain
/// Kotlin BroadcastReceiver in a process where Dart does not exist. It has to
/// be: flutter_local_notifications posts its notification natively without ever
/// starting an isolate, so there is no Dart callback at fire time to hook, and
/// a callback that did exist would add Flutter's cold start to the very number
/// being measured.
///
/// Every method here is best-effort and swallows failure. This is diagnostics;
/// it may never be the reason a reminder does not fire.
class ReminderAuditLog {
  const ReminderAuditLog();

  static const _channel = MethodChannel('time_app/reminder_audit');

  /// Arms the silent shadow alarm at the same instant as the real reminder.
  /// Returns the native outcome string (`ok`, `exact_alarm_denied`, …) so a
  /// caller can log it; never throws.
  Future<String> arm({
    required int id,
    required String itemId,
    required DateTime fireAtUtc,
  }) async {
    return await _invoke<String>('arm', {
          'id': id,
          'itemId': itemId,
          'fireAtMillis': fireAtUtc.millisecondsSinceEpoch,
        }) ??
        'unavailable';
  }

  Future<void> cancel(int id) => _invoke<void>('cancel', {'id': id});

  Future<void> cancelAll() => _invoke<void>('cancelAll', const {});

  /// Appends a row for something Dart did — arming, cancelling, reconciling,
  /// a tap. Fire-and-forget by design: nothing in the reminder path waits on the
  /// instrument, so this is deliberately not awaited at its call sites.
  void note({
    required String event,
    String itemId = '',
    int? id,
    DateTime? fireAtUtc,
    String note = '',
  }) {
    _invoke<void>('note', {
      'event': event,
      'itemId': itemId,
      'id': id,
      'fireAtMillis': fireAtUtc?.millisecondsSinceEpoch,
      'note': note,
    });
  }

  /// The whole CSV, header included. Empty string when there is nothing (or on
  /// a platform with no implementation).
  Future<String> read() async => await _invoke<String>('read', const {}) ?? '';

  Future<void> clear() => _invoke<void>('clear', const {});

  /// Where the file lives on the device, for `adb pull`.
  Future<String> path() async => await _invoke<String>('path', const {}) ?? '';

  Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // Expected off Android (and in unit tests, which have no platform side).
      return null;
    } catch (e) {
      debugPrint('ReminderAuditLog: $method failed: $e');
      return null;
    }
  }
}
