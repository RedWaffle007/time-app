import '../../social/application/streak_policy.dart';
import '../../social/domain/profile_stat.dart';

/// **The Stats page — one pure function over the user's own record** (item
/// 24b, DECISIONS.md "24b — the new Stats page").
///
/// Private by construction: nothing here is published. What another person may
/// see is the registry's subset (`kProfileStatDefinitions`). No clock, no
/// Firestore, no context — `test/my_stats_test.dart` drives it directly.

/// Done / deliberately skipped / missed within one window.
class OutcomeCounts {
  const OutcomeCounts({
    required this.done,
    required this.skipped,
    required this.missed,
  });

  static const zero = OutcomeCounts(done: 0, skipped: 0, missed: 0);

  final int done;

  /// Deliberate skips only.
  final int skipped;

  /// Auto-skips nobody answered.
  final int missed;

  int get total => done + skipped + missed;
}

/// One person who set alarms for the user, and how many.
class PlannerCount {
  const PlannerCount({required this.uid, required this.count});

  final String uid;
  final int count;
}

/// The minimum the page needs to know about one outgoing plan request.
class RequestSummary {
  const RequestSummary({
    required this.fulfilled,
    required this.declined,
    required this.cancelled,
    required this.open,
    required this.windowEndUtc,
    this.expired = false,
  });

  final bool fulfilled;
  final bool declined;
  final bool cancelled;
  final bool open;

  /// Closed by the Worker because its time passed unplanned (2026-09-28).
  final bool expired;
  final DateTime windowEndUtc;
}

/// Everything the Stats page renders.
class MyStats {
  const MyStats({
    required this.last7,
    required this.previous7,
    required this.followThrough,
    required this.followThroughSetForYou,
    required this.followThroughSelf,
    required this.answeredWhenRang,
    required this.settledCount,
    required this.streaks,
    required this.setForYouCount,
    required this.topPlanners,
    required this.alarmsSetCount,
    required this.alarmsSetCompletion,
    required this.requestsFulfilled,
    required this.requestsAnswered,
    required this.requestsClosed,
    required this.weeklyDone,
    required this.isEmpty,
  });

  /// The rolling last 7 days, and the 7 before (by scheduled time).
  final OutcomeCounts last7;
  final OutcomeCounts previous7;

  /// Percentages are null until [kMinStatSample] plans stand behind them.
  final int? followThrough;
  final int? followThroughSetForYou;
  final int? followThroughSelf;
  final int? answeredWhenRang;

  /// Plans with an outcome — the denominator behind the headline percentages.
  final int settledCount;

  final Streaks streaks;

  /// Alarms other people set for the user (not cancelled).
  final int setForYouCount;

  /// Up to three people who set the most, most first.
  final List<PlannerCount> topPlanners;

  /// Alarms the user set for other people (not cancelled).
  final int alarmsSetCount;

  /// Share of those that were completed, once enough were answered.
  final int? alarmsSetCompletion;

  /// Alarms the user set while fulfilling a friend's request.
  final int requestsFulfilled;

  /// The user's own requests: fulfilled out of those that are closed.
  final int requestsAnswered;
  final int requestsClosed;

  /// Done per rolling week, OLDEST first, eight entries; the last entry is the
  /// same window as [last7].
  final List<int> weeklyDone;

  /// No plans at all, in either role — the page shows its empty state.
  final bool isEmpty;
}

/// Build the page from the RECORD (never the archive-filtered views — see
/// `profile_stat.dart`).
MyStats buildMyStats({
  required List<StatItem> itemsAsTarget,
  required List<StatItem> itemsAsPlanner,
  required List<RequestSummary> outgoingRequests,
  required DateTime now,
  required String timezone,
}) {
  final nowUtc = now.toUtc();
  final target = itemsAsTarget.where((i) => !i.isCancelled).toList();
  final forOthers = itemsAsPlanner
      .where((i) => !i.isSelfPlan && !i.isCancelled)
      .toList();
  final setForYou = target.where((i) => !i.isSelfPlan).toList();
  final self = target.where((i) => i.isSelfPlan).toList();

  OutcomeCounts window(DateTime startExclusive, DateTime endInclusive) {
    var done = 0, skipped = 0, missed = 0;
    for (final i in target) {
      if (!i.instantUtc.isAfter(startExclusive) ||
          i.instantUtc.isAfter(endInclusive)) {
        continue;
      }
      if (i.isDone) {
        done++;
      } else if (i.isMissed) {
        missed++;
      } else if (i.isSkipped) {
        skipped++;
      }
    }
    return OutcomeCounts(done: done, skipped: skipped, missed: missed);
  }

  const week = Duration(days: 7);
  final weeklyDone = [
    for (var k = 7; k >= 0; k--)
      window(nowUtc.subtract(week * (k + 1)), nowUtc.subtract(week * k)).done,
  ];

  final settled = target.where((i) => i.hasOutcome).toList();
  final answered = settled.where((i) => !i.isMissed && !i.wasUnavailable);

  final byPlanner = <String, int>{};
  for (final i in setForYou) {
    final uid = i.creatorUid;
    if (uid == null) continue;
    byPlanner[uid] = (byPlanner[uid] ?? 0) + 1;
  }
  final topPlanners =
      [
        for (final e in byPlanner.entries)
          PlannerCount(uid: e.key, count: e.value),
      ]..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.uid.compareTo(b.uid);
      });

  final closed = outgoingRequests.where(
    (r) =>
        !r.cancelled &&
        (r.fulfilled ||
            r.declined ||
            r.expired ||
            (r.open && !r.windowEndUtc.isAfter(nowUtc))),
  );

  return MyStats(
    last7: window(nowUtc.subtract(week), nowUtc),
    previous7: window(nowUtc.subtract(week * 2), nowUtc.subtract(week)),
    followThrough: completionRate(target),
    followThroughSetForYou: completionRate(setForYou),
    followThroughSelf: completionRate(self),
    answeredWhenRang: _rate(answered.length, settled.length),
    settledCount: settled.length,
    streaks: computeStreaks(target, timezone),
    setForYouCount: setForYou.length,
    topPlanners: topPlanners.take(3).toList(growable: false),
    alarmsSetCount: forOthers.length,
    alarmsSetCompletion: completionRate(forOthers),
    requestsFulfilled: forOthers.where((i) => i.fromPlanRequest).length,
    requestsAnswered: closed.where((r) => r.fulfilled).length,
    requestsClosed: closed.length,
    weeklyDone: weeklyDone,
    isEmpty: itemsAsTarget.isEmpty && itemsAsPlanner.isEmpty,
  );
}

/// Done ÷ everything answered (done + skipped + missed), as a whole percent —
/// null below [kMinStatSample] answered plans.
int? completionRate(List<StatItem> items) {
  final settled = items.where((i) => i.hasOutcome).length;
  final done = items.where((i) => i.isDone).length;
  return _rate(done, settled);
}

int? _rate(int part, int whole) {
  if (whole < kMinStatSample) return null;
  return ((part / whole) * 100).round();
}
