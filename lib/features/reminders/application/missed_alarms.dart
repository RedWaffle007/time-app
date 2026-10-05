import '../../scheduling/domain/schedule_item.dart';

/// **What the Missed pop-up and the 🔔 Missed button show** (2026-10-05,
/// user-directed). Pure: no clock, no plugins, no Firestore.
///
/// An alarm is waiting for an answer when ALL of:
///
///   * it is mine (I am the target) and approved;
///   * it has no answer: no outcome (Done / Skip / heard) and no dismissal;
///   * it has rung at least once — its time has passed and the target phone
///     reported a ring ([ScheduleAlarmTimeline.rangAt] / `ring`), it ran out
///     (`unavailableAt`), or this phone recorded a timeout ([timedOutIds]);
///   * it is not ringing right now ([ringingIds]) — that one is on the alarm
///     screen instead.
///
/// That covers an alarm silenced with Volume Down, one waiting for its next
/// repeat, and one that ran out. Answering it in the pop-up records an
/// outcome, and the reminder reconciler then stops its repeats (a present,
/// answered plan loses its alarm) — no extra hook here.
class MissedAlarms {
  const MissedAlarms({required this.voice, required this.alarms});

  /// Voice notes, shown first, oldest planned time first.
  final List<ScheduleItem> voice;

  /// Default alarms (including self-plans), shown after, oldest first.
  final List<ScheduleItem> alarms;

  int get count => voice.length + alarms.length;
  bool get isEmpty => count == 0;

  static const none = MissedAlarms(voice: [], alarms: []);
}

MissedAlarms missedAlarms({
  required List<ScheduleItem> items,
  required String? uid,
  required DateTime nowUtc,
  Set<String> ringingIds = const {},
  Set<String> timedOutIds = const {},
}) {
  if (uid == null) return MissedAlarms.none;
  final voice = <ScheduleItem>[];
  final alarms = <ScheduleItem>[];
  for (final item in items) {
    if (!isWaitingForAnswer(
      item,
      uid: uid,
      nowUtc: nowUtc,
      ringingIds: ringingIds,
      timedOutIds: timedOutIds,
    )) {
      continue;
    }
    (item.isVoiceAlarm ? voice : alarms).add(item);
  }
  int byTime(ScheduleItem a, ScheduleItem b) {
    final t = a.scheduledInstantUtc.compareTo(b.scheduledInstantUtc);
    return t != 0 ? t : a.id.compareTo(b.id);
  }

  voice.sort(byTime);
  alarms.sort(byTime);
  return MissedAlarms(voice: voice, alarms: alarms);
}

/// One item against the rule above. Pure, for tests.
bool isWaitingForAnswer(
  ScheduleItem item, {
  required String uid,
  required DateTime nowUtc,
  Set<String> ringingIds = const {},
  Set<String> timedOutIds = const {},
}) {
  final alarm = item.alarm;
  if (item.targetUid != uid ||
      item.status != ScheduleItemStatus.approved ||
      item.outcome != null ||
      alarm?.dismissedAt != null ||
      ringingIds.contains(item.id) ||
      item.scheduledInstantUtc.isAfter(nowUtc)) {
    return false;
  }
  return alarm?.rangAt != null ||
      alarm?.ring != null ||
      alarm?.unavailableAt != null ||
      timedOutIds.contains(item.id);
}
