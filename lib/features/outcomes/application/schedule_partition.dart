import '../../scheduling/domain/schedule_item.dart';

/// The two mutually-exclusive target-side schedule surfaces.
enum ScheduleSurface { upcoming, history }

/// Decides where an approved plan belongs at [nowUtc].
///
/// **Only a decision moves a plan to History.** An outcome — Done or Skipped,
/// by the person, on another device, or by the end-of-day lapse — moves it
/// immediately, even if recorded before the scheduled instant. Time passing
/// does NOT: a plan whose alarm was dismissed or ignored stays in My Schedule,
/// where its Done/Skip controls live, until it is decided. (It cannot linger
/// forever: the end-of-day lapse settles it at its own local midnight.)
///
/// [nowUtc] is kept so callers stay clock-driven; it asserts a UTC clock.
ScheduleSurface scheduleSurfaceFor(ScheduleItem item, DateTime nowUtc) {
  assert(nowUtc.isUtc, 'The schedule partition clock must be UTC.');
  if (item.outcome != null) {
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

/// A plan [plannerUid] set for SOMEONE ELSE that is still open — no Done/Skip
/// yet, not cancelled, not lapsed (Batch G item 7, 2026-09-27). It lives on
/// Home beside your own plans until the other person answers it.
bool isOpenPlanForOthers(ScheduleItem item, String plannerUid) =>
    item.createdByUid == plannerUid &&
    item.targetUid != plannerUid &&
    item.outcome == null &&
    (item.status == ScheduleItemStatus.approved ||
        item.status == ScheduleItemStatus.pending);

/// …and once it is answered (Done / Skipped, or lapsed to "Did not respond")
/// it moves to Activity. Cancelled plans are hidden from both.
bool isSettledPlanForOthers(ScheduleItem item, String plannerUid) =>
    item.createdByUid == plannerUid &&
    item.targetUid != plannerUid &&
    item.outcome != null;
