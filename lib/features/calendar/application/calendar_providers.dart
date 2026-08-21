import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../scheduling/application/schedule_providers.dart';
import 'calendar_grouping.dart';

/// **The calendar owns no data.** These two providers are projections of
/// `myItemsAsTargetProvider` and `myItemsAsPlannerProvider`, which existed
/// before this feature and are unchanged by it. There is no calendar
/// collection, no calendar document and no calendar Firestore rule.
///
/// They read the **VIEW** layer, not the RECORD layer, and that is correct
/// here: `schedule_providers.dart` requires stats and summaries to aggregate
/// the record so archiving cannot quietly drop rows from someone's own totals.
/// A calendar is a feed, not a total — an item the user archived should
/// disappear from the grid exactly as it disappears from every other feed.

/// Every item the calendar plots, both roles merged and deduped.
final calendarEntriesProvider =
    Provider<AsyncValue<List<CalendarEntry>>>((ref) {
  final uid = ref.watch(currentUidProvider);
  final asTarget = ref.watch(myItemsAsTargetProvider);
  final asPlanner = ref.watch(myItemsAsPlannerProvider);

  // Either stream failing is a real failure of the calendar — it would render a
  // half-empty month with no indication that half of it is missing, which is
  // worse than the retry AsyncView already knows how to draw.
  if (asTarget.hasError) {
    return AsyncError(asTarget.error!, asTarget.stackTrace ?? StackTrace.empty);
  }
  if (asPlanner.hasError) {
    return AsyncError(
        asPlanner.error!, asPlanner.stackTrace ?? StackTrace.empty);
  }

  final target = asTarget.value;
  final planner = asPlanner.value;
  if (target == null || planner == null) return const AsyncLoading();

  return AsyncData(calendarEntries(
    asTarget: target,
    asPlanner: planner,
    viewerUid: uid,
  ));
});

/// The same entries indexed by grid cell.
///
/// Derived once per emission rather than in each cell's builder: a month is 42
/// cells, and filtering the full list inside each would be 42 passes over every
/// item the user has, on every frame the grid rebuilds.
final calendarDayIndexProvider =
    Provider<AsyncValue<Map<DateTime, List<CalendarEntry>>>>((ref) {
  return ref.watch(calendarEntriesProvider).whenData(groupEntriesByDay);
});
