import 'package:timezone/timezone.dart' as tz;

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

/// The chart's time range (2026-09-28): the dropdown over the bars.
enum StatsRange { weeks, months, years }

/// Plans done per period over one [StatsRange], OLDEST first. Empty periods
/// are zeros, never missing, so a new user's chart is empty, not broken.
class DoneSeries {
  const DoneSeries({
    required this.starts,
    required this.done,
    required this.lateCount,
  });

  /// Each period's first day as a wall date in the home zone (a UTC-kind
  /// carrier, like `calendarDayFor`) — for labels.
  final List<DateTime> starts;
  final List<int> done;

  /// Done (Late) / Heard (Late) within the whole range.
  final int lateCount;
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
    required this.series,
    required this.voiceHeard,
    required this.voiceHeardLate,
    required this.voiceAnswered,
    required this.groupFollowThrough,
    required this.medianAnswerMinutes,
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

  /// The chart, per range. Weeks: eight rolling weeks, the last being the
  /// same window as [last7]. Months: the last 12 calendar months. Years:
  /// every year since the first plan, at least three.
  final Map<StatsRange, DoneSeries> series;

  List<int> get weeklyDone => series[StatsRange.weeks]!.done;

  /// Voice notes others sent the user: heard (on time or late), of those
  /// answered or missed.
  final int voiceHeard;
  final int voiceHeardLate;
  final int voiceAnswered;

  /// Follow-through on group plans only, once enough were answered.
  final int? groupFollowThrough;

  /// The usual time from the alarm to Done / Heard, in whole minutes — the
  /// median, once enough plans stand behind it.
  final int? medianAnswerMinutes;

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
  final series = {
    StatsRange.weeks: _weekSeries(target, nowUtc),
    StatsRange.months: _calendarSeries(target, nowUtc, timezone, years: false),
    StatsRange.years: _calendarSeries(target, nowUtc, timezone, years: true),
  };

  final voice = target.where((i) => i.isVoice && i.hasOutcome).toList();
  final answerMinutes = [
    for (final i in target)
      if (i.isDone &&
          i.doneAtUtc != null &&
          !i.doneAtUtc!.isBefore(i.instantUtc))
        i.doneAtUtc!.difference(i.instantUtc).inMinutes,
  ]..sort();

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
    series: series,
    voiceHeard: voice.where((i) => i.isDone).length,
    voiceHeardLate: voice.where((i) => i.isLate).length,
    voiceAnswered: voice.length,
    groupFollowThrough: completionRate(
      target.where((i) => i.groupId.isNotEmpty).toList(),
    ),
    medianAnswerMinutes: answerMinutes.length < kMinStatSample
        ? null
        : answerMinutes[answerMinutes.length ~/ 2],
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

/// Eight rolling 7-day windows ending now, oldest first.
DoneSeries _weekSeries(List<StatItem> target, DateTime nowUtc) {
  const week = Duration(days: 7);
  final starts = <DateTime>[];
  final done = <int>[];
  var late = 0;
  for (var k = 7; k >= 0; k--) {
    final from = nowUtc.subtract(week * (k + 1));
    final to = nowUtc.subtract(week * k);
    starts.add(to.subtract(week));
    var n = 0;
    for (final i in target) {
      if (!i.instantUtc.isAfter(from) || i.instantUtc.isAfter(to)) continue;
      if (i.isDone) n++;
      if (i.isLate) late++;
    }
    done.add(n);
  }
  return DoneSeries(starts: starts, done: done, lateCount: late);
}

/// Calendar months (the last 12) or years (since the first plan, at least
/// three) in the HOME zone, oldest first. An unknown zone falls back to UTC.
DoneSeries _calendarSeries(
  List<StatItem> target,
  DateTime nowUtc,
  String timezone, {
  required bool years,
}) {
  tz.Location location;
  try {
    location = tz.getLocation(timezone);
  } catch (_) {
    location = tz.UTC;
  }
  DateTime periodOf(DateTime utc) {
    final local = tz.TZDateTime.from(utc, location);
    return DateTime.utc(local.year, years ? 1 : local.month);
  }

  final current = periodOf(nowUtc);
  final List<DateTime> starts;
  if (years) {
    var first = current.year - 2;
    for (final i in target) {
      final y = periodOf(i.instantUtc).year;
      if (y < first) first = y;
    }
    starts = [for (var y = first; y <= current.year; y++) DateTime.utc(y)];
  } else {
    starts = [
      for (var k = 11; k >= 0; k--)
        DateTime.utc(current.year, current.month - k),
    ];
  }
  final index = {for (var k = 0; k < starts.length; k++) starts[k]: k};
  final done = List<int>.filled(starts.length, 0);
  var late = 0;
  for (final i in target) {
    final k = index[periodOf(i.instantUtc)];
    if (k == null) continue;
    if (i.isDone) done[k]++;
    if (i.isLate) late++;
  }
  return DoneSeries(starts: starts, done: done, lateCount: late);
}
