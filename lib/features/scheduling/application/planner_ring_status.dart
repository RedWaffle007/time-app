import '../../reminders/application/ring_cycle.dart';
import '../domain/schedule_item.dart';

/// **What the planner sees while their alarm is going off** (2026-10-04,
/// user-directed: no push per ring, just the live state on the card).
///
/// Worked out from facts the item already carries — that it rang
/// (`alarm.rangAt`) and its time — plus the fixed ring cycle. Nothing new is
/// written, and no push is sent; the planner hears only "dismissed"/"heard"
/// or, after 25 minutes, "unavailable", as before.
///
/// Null when there is nothing live to say: not rung yet as far as this phone
/// knows (the target's phone reports the ring when it can), already answered,
/// dismissed, or ran out.
RingPhase? plannerRingStatus(ScheduleItem item, DateTime nowUtc) {
  final alarm = item.alarm;
  if (item.status != ScheduleItemStatus.approved ||
      item.outcome != null ||
      alarm?.rangAt == null ||
      alarm?.dismissedAt != null ||
      alarm?.unavailableAt != null) {
    return null;
  }
  final phase = ringPhaseAt(item.scheduledInstantUtc, nowUtc);
  if (phase is RingOver) return null;
  // Before its time the cycle reads as "ring 1"; a rang fact that early is
  // not real ringing.
  if (nowUtc.isBefore(item.scheduledInstantUtc)) return null;
  return phase;
}
