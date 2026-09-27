import 'package:time_app/features/social/application/streak_policy.dart';
import 'package:time_app/features/stats/application/my_stats.dart';

/// A populated Stats page for screen tests (item 24b). Values are chosen to be
/// unique on screen so a `find.text` can locate each one.
MyStats sampleMyStats({
  List<PlannerCount> topPlanners = const [],
  bool empty = false,
}) => MyStats(
  last7: const OutcomeCounts(done: 12, skipped: 2, missed: 1),
  previous7: const OutcomeCounts(done: 9, skipped: 0, missed: 0),
  followThrough: 86,
  followThroughSetForYou: 90,
  followThroughSelf: 80,
  answeredWhenRang: 92,
  settledCount: 40,
  streaks: const Streaks(current: 4, best: 11),
  setForYouCount: 23,
  topPlanners: topPlanners,
  alarmsSetCount: 18,
  alarmsSetCompletion: null,
  requestsFulfilled: 5,
  requestsAnswered: 3,
  requestsClosed: 7,
  weeklyDone: const [0, 1, 2, 3, 4, 6, 9, 12],
  isEmpty: empty,
);
