import '../domain/schedule_item.dart';

/// What the planner's card says while their alarm is going (2026-10-05).
sealed class PlannerRingStatus {
  const PlannerRingStatus();
}

/// Sounding now: ring 1 (the alarm itself) or a repeat.
class PlannerRinging extends PlannerRingStatus {
  const PlannerRinging(this.ring);
  final int ring;
}

/// Rang [ringsDone] time(s) unanswered; waiting for the next ring, expected
/// around [nextRingAtUtc] when the target's phone forecast one. New alarms go
/// first, so the time can move.
class PlannerWaiting extends PlannerRingStatus {
  const PlannerWaiting(this.ringsDone, this.nextRingAtUtc);
  final int ringsDone;
  final DateTime? nextRingAtUtc;
}

/// **What the planner sees while their alarm is going off** (ring queue,
/// 2026-10-05; no push per ring).
///
/// Read from the ring record the target's phone writes on the item
/// (`alarm.ring` / `ringAt` / `ringEndsAt` / `nextRingAt`), because repeats
/// now move as new plans arrive and the planner's phone cannot work the
/// timing out by itself.
///
/// Null when there is nothing live to say: no ring recorded yet, already
/// answered, dismissed, or missed ("unavailable" says that instead).
PlannerRingStatus? plannerRingStatus(ScheduleItem item, DateTime nowUtc) {
  final alarm = item.alarm;
  final ring = alarm?.ring;
  final ringAt = alarm?.ringAt;
  if (item.status != ScheduleItemStatus.approved ||
      item.outcome != null ||
      alarm == null ||
      ring == null ||
      ringAt == null ||
      alarm.dismissedAt != null ||
      alarm.unavailableAt != null) {
    return null;
  }
  final ends = alarm.ringEndsAt;
  if (!nowUtc.isBefore(ringAt) && (ends == null || nowUtc.isBefore(ends))) {
    return PlannerRinging(ring);
  }
  if (ends != null && !nowUtc.isBefore(ends) && ring < kPlannerRingCount) {
    return PlannerWaiting(ring, alarm.nextRingAt);
  }
  return null;
}

/// Rings per alarm, for "2 of 3" (native `RingQueuePolicy.RINGS`).
const kPlannerRingCount = 3;
