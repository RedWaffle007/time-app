import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The alarm PLAYBACK lifecycle — start the looping tone when the alarm screen
/// appears, stop it on dismiss.
///
/// The sound does NOT live here or in the Dart UI: it lives in the native
/// `AlarmSoundService`, a foreground service holding a wake lock, so it keeps
/// ringing with the screen off, each ring bounded by the native 5-minute cap. This is
/// only the switch. `start` also drives the window flags that show the alarm
/// over the lock screen; `stop` clears them.
///
/// A hand-written channel rather than a package, the same call [SecureWindow]
/// makes: the job is two verbs over one native service, and an audio package
/// would not own the wake lock or the foreground-service type this needs.
/// A voice note for the native queue: the file on this phone and what it
/// must match (2026-10-05).
class AlarmVoice {
  const AlarmVoice({
    required this.path,
    required this.sha256,
    required this.sizeBytes,
    required this.durationMs,
  });
  final String path;
  final String sha256;
  final int sizeBytes;
  final int durationMs;
}

/// One alarm in the segment ringing now (2026-10-05), as the native queue
/// holds it: enough to name it on screen before the item stream loads.
class RingingAlarm {
  const RingingAlarm({
    required this.itemId,
    required this.headline,
    required this.scheduledAtUtc,
    required this.ring,
    required this.voice,
    required this.sounding,
  });

  final String itemId;

  /// "{planner} planned {task} for you" / "{planner} sent you a voice alarm".
  final String headline;
  final DateTime? scheduledAtUtc;

  /// 1 for a new alarm's ring; 2 or 3 for its repeats.
  final int ring;
  final bool voice;

  /// The one whose sound is playing right now.
  final bool sounding;

  static RingingAlarm? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['itemId'];
    if (id is! String || id.isEmpty) return null;
    final at = raw['scheduledAtMillis'];
    final ring = raw['ring'];
    return RingingAlarm(
      itemId: id,
      headline: raw['headline'] is String ? raw['headline'] as String : '',
      scheduledAtUtc: at is int && at > 0
          ? DateTime.fromMillisecondsSinceEpoch(at, isUtc: true)
          : null,
      ring: ring is int && ring > 0 ? ring : 1,
      voice: raw['voice'] == true,
      sounding: raw['sounding'] == true,
    );
  }
}

abstract interface class AlarmSound {
  /// Puts [itemId] in the native ring queue if it is not there yet (at
  /// [scheduledAtUtc], its plan time, with its [voice] note when it has one)
  /// and lets the queue look now.
  Future<void> start(
    String itemId, {
    String headline = '',
    DateTime? scheduledAtUtc,
    AlarmVoice? voice,
  });
  Future<void> stop(String itemId);

  /// The sentence the native alarm was delivered with ("{planner} planned {task} for
  /// you"), or null when this process did not receive one.
  Future<String?> headline(String itemId);

  /// The plan ringing right now, or null (R5, 2026-10-02): an app opened
  /// mid-ring shows that alarm instead of only playing its tone.
  Future<String?> ringingItem();

  /// Every alarm in the segment ringing right now (2026-10-05): one new
  /// alarm, or a batch of repeats.
  Future<List<String>> ringingItems();

  /// The alarms in the segment ringing now, in order (2026-10-05).
  Future<List<RingingAlarm>> segmentDetails();

  /// When [itemId] rings next if nothing new is planned (the native queue's
  /// forecast), or null when it is not in the queue (2026-10-05).
  Future<DateTime?> nextRingAt(String itemId);

  /// Ends an alarm opened after its ring cycle ran out ([alarmScreenPhase])
  /// as missed, with no sound: missed notice, missed popup, planner told.
  Future<void> missLate(String itemId, {String headline = ''});

  /// Called with the item id whenever an alarm starts ringing while this app
  /// is alive (R5). Null stops listening.
  void onRinging(void Function(String itemId)? listener);
}

class PlatformAlarmSound implements AlarmSound {
  const PlatformAlarmSound();

  static const _channel = MethodChannel('time_app/alarm_sound');

  @override
  Future<void> start(
    String itemId, {
    String headline = '',
    DateTime? scheduledAtUtc,
    AlarmVoice? voice,
  }) => _invoke('start', itemId, {
    'headline': headline,
    'scheduledAtMillis': ?scheduledAtUtc?.millisecondsSinceEpoch,
    'voicePath': ?voice?.path,
    'voiceSha256': ?voice?.sha256,
    'voiceSizeBytes': ?voice?.sizeBytes,
    'voiceDurationMs': ?voice?.durationMs,
  });

  @override
  Future<List<RingingAlarm>> segmentDetails() async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('segmentDetails');
      return [
        for (final r in raw ?? const <Object?>[]) ?RingingAlarm.fromMap(r),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (e) {
      debugPrint('alarm_sound: segmentDetails failed: $e');
      return const [];
    }
  }

  @override
  Future<DateTime?> nextRingAt(String itemId) async {
    try {
      final ms = await _channel.invokeMethod<int>('nextRingAt', {
        'itemId': itemId,
      });
      return ms == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('alarm_sound: nextRingAt failed: $e');
      return null;
    }
  }

  @override
  Future<void> stop(String itemId) => _invoke('stop', itemId);

  @override
  Future<String?> ringingItem() async {
    try {
      final id = await _channel.invokeMethod<String>('ringingItem');
      return id == null || id.isEmpty ? null : id;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('alarm_sound: ringingItem failed: $e');
      return null;
    }
  }

  @override
  Future<List<String>> ringingItems() async {
    try {
      final ids = await _channel.invokeListMethod<String>('ringingItems');
      return [
        for (final id in ids ?? const <String>[])
          if (id.isNotEmpty) id,
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (e) {
      debugPrint('alarm_sound: ringingItems failed: $e');
      return const [];
    }
  }

  @override
  Future<void> missLate(String itemId, {String headline = ''}) =>
      _invoke('missLate', itemId, {'headline': headline});

  @override
  void onRinging(void Function(String itemId)? listener) {
    _channel.setMethodCallHandler(
      listener == null
          ? null
          : (call) async {
              if (call.method != 'ringing') return;
              final args = call.arguments;
              final id = args is Map ? args['itemId'] : null;
              if (id is String && id.isNotEmpty) listener(id);
            },
    );
  }

  @override
  Future<String?> headline(String itemId) async {
    try {
      return await _channel.invokeMethod<String>('headline', {
        'itemId': itemId,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('alarm_sound: headline failed: $e');
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
      debugPrint('alarm_sound: $method failed: $e');
    }
  }
}
