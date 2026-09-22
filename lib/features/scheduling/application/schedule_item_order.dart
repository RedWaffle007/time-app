import '../../calendar/application/calendar_grouping.dart';
import '../domain/schedule_item.dart';

/// Latest scheduled time first, with deterministic tie-breakers so Firestore's
/// snapshot order cannot make equal-time cards swap between rebuilds.
int compareScheduleItemsLatestFirst(ScheduleItem a, ScheduleItem b) {
  final byInstant = b.scheduledInstantUtc.compareTo(a.scheduledInstantUtc);
  if (byInstant != 0) return byInstant;
  final byTitle = a.title.compareTo(b.title);
  return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
}

/// Date groups remain soonest-first, but cards within the same item-local date
/// are latest-first. Used by an ungrouped feed such as Pending Approvals, where
/// reversing the whole list would also reverse the intended date priority.
int compareScheduleItemsDayAscendingLatestFirst(
  ScheduleItem a,
  ScheduleItem b,
) {
  final byDay = calendarDayFor(a).compareTo(calendarDayFor(b));
  return byDay != 0 ? byDay : compareScheduleItemsLatestFirst(a, b);
}
