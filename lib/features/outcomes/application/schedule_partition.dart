import '../../scheduling/domain/schedule_item.dart';

/// The two mutually-exclusive target-side schedule surfaces.
enum ScheduleSurface { upcoming, history }

/// Decides where an approved plan belongs at [nowUtc].
///
/// This boundary compares absolute instants, never device-local dates. It is
/// therefore stable across midnight, timezone changes, and DST transitions.
/// Equality remains upcoming: the plan becomes elapsed only after its due
/// instant. An outcome always wins and moves the plan to History immediately,
/// even if it was recorded before the scheduled instant.
ScheduleSurface scheduleSurfaceFor(ScheduleItem item, DateTime nowUtc) {
  assert(nowUtc.isUtc, 'The schedule partition clock must be UTC.');
  if (item.outcome != null || item.scheduledInstantUtc.isBefore(nowUtc)) {
    return ScheduleSurface.history;
  }
  return ScheduleSurface.upcoming;
}

bool isUpcomingPlan(ScheduleItem item, DateTime nowUtc) =>
    item.status == ScheduleItemStatus.approved &&
    scheduleSurfaceFor(item, nowUtc) == ScheduleSurface.upcoming;

bool isHistoryPlan(ScheduleItem item, DateTime nowUtc) =>
    item.status == ScheduleItemStatus.approved &&
    scheduleSurfaceFor(item, nowUtc) == ScheduleSurface.history;
