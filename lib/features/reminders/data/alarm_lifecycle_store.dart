import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum AlarmLifecycleEventKind { timeout, dismissed }

class AlarmLifecycleEvent {
  const AlarmLifecycleEvent({
    required this.key,
    required this.itemId,
    required this.occurredAtUtc,
    required this.kind,
    required this.outcomeRecorded,
    required this.notificationDelivered,
    required this.reviewed,
  });

  final String key;
  final String itemId;
  final DateTime occurredAtUtc;
  final AlarmLifecycleEventKind kind;
  final bool outcomeRecorded;
  final bool notificationDelivered;
  final bool reviewed;

  static AlarmLifecycleEvent? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final itemId = raw['itemId'];
    final epoch = raw['occurredAtEpoch'];
    final kind = raw['kind'];
    if (key is! String || itemId is! String || epoch is! int) return null;
    final parsedKind = switch (kind) {
      'timeout' => AlarmLifecycleEventKind.timeout,
      'volume_silenced' || 'dismissed' => AlarmLifecycleEventKind.dismissed,
      _ => null,
    };
    if (parsedKind == null) return null;
    return AlarmLifecycleEvent(
      key: key,
      itemId: itemId,
      occurredAtUtc: DateTime.fromMillisecondsSinceEpoch(epoch, isUtc: true),
      kind: parsedKind,
      outcomeRecorded: raw['outcomeRecorded'] == true,
      notificationDelivered: raw['notificationDelivered'] == true,
      reviewed: raw['reviewed'] == true,
    );
  }
}

abstract interface class AlarmLifecycleStore {
  Future<List<AlarmLifecycleEvent>> read();
  void listen(Future<void> Function()? onChanged);
  Future<void> markOutcomeRecorded(String key);
  Future<void> markNotificationDelivered(String key);
  Future<void> markReviewed(String key);
  Future<void> remove(String key);
}

class PlatformAlarmLifecycleStore implements AlarmLifecycleStore {
  const PlatformAlarmLifecycleStore();

  static const _channel = MethodChannel('time_app/alarm_lifecycle');

  @override
  void listen(Future<void> Function()? onChanged) {
    _channel.setMethodCallHandler(
      onChanged == null
          ? null
          : (call) async {
              if (call.method == 'changed') await onChanged();
            },
    );
  }

  @override
  Future<List<AlarmLifecycleEvent>> read() async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('read') ?? const [];
      return [for (final value in raw) ?AlarmLifecycleEvent.fromMap(value)];
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (error) {
      debugPrint('alarm_lifecycle: read failed — $error');
      return const [];
    }
  }

  @override
  Future<void> markOutcomeRecorded(String key) =>
      _update('markOutcomeRecorded', key);

  @override
  Future<void> markNotificationDelivered(String key) =>
      _update('markNotificationDelivered', key);

  @override
  Future<void> markReviewed(String key) => _update('markReviewed', key);

  @override
  Future<void> remove(String key) => _update('remove', key);

  Future<void> _update(String method, String key) async {
    try {
      await _channel.invokeMethod<void>(method, {'key': key});
    } on MissingPluginException {
      // Expected outside Android.
    } on PlatformException catch (error) {
      debugPrint('alarm_lifecycle: $method failed — $error');
      rethrow;
    }
  }
}

abstract interface class AlarmKeyEvents {
  void listen(Future<void> Function()? onVolumeSilenced);
}

class PlatformAlarmKeyEvents implements AlarmKeyEvents {
  const PlatformAlarmKeyEvents();

  static const _channel = MethodChannel('time_app/alarm_keys');

  @override
  void listen(Future<void> Function()? onVolumeSilenced) {
    _channel.setMethodCallHandler(
      onVolumeSilenced == null
          ? null
          : (call) async {
              if (call.method == 'volumeSilenced') {
                await onVolumeSilenced();
              }
            },
    );
  }
}
