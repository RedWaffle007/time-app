import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/scheduling/application/item_lapse_policy.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/social/application/stats_providers.dart';
import 'package:time_app/features/social/application/streak_policy.dart';
import 'package:time_app/features/social/domain/profile_stat.dart';
import 'package:time_app/features/stats/application/my_stats.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// The private Stats page (item 24b): the humane streak, missed vs skipped,
/// the minimum sample, rolling windows and the relationship tiles — all pure.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  const zone = 'Asia/Karachi'; // UTC+5, no DST.
  final now = DateTime.utc(2026, 9, 27, 7); // 12:00 in Karachi.

  StatItem item({
    required DateTime at,
    bool done = false,
    bool skipped = false,
    bool missed = false,
    bool unavailable = false,
    bool self = true,
    bool cancelled = false,
    String? creator,
    bool fromRequest = false,
  }) => StatItem(
    instantUtc: at,
    isApproved: true,
    isDone: done,
    isSkipped: skipped || missed,
    isMissed: missed,
    wasUnavailable: unavailable,
    isSelfPlan: self,
    isCancelled: cancelled,
    creatorUid: creator ?? (self ? 'me' : 'friend'),
    fromPlanRequest: fromRequest,
  );

  DateTime daysAgo(int d, {int hour = 12}) =>
      DateTime.utc(2026, 9, 27 - d, hour - 5);

  MyStats build({
    List<StatItem> target = const [],
    List<StatItem> planner = const [],
    List<RequestSummary> requests = const [],
    String timezone = zone,
  }) => buildMyStats(
    itemsAsTarget: target,
    itemsAsPlanner: planner,
    outgoingRequests: requests,
    now: now,
    timezone: timezone,
  );

  group('missed vs skipped', () {
    test('the mapper marks only automatic skips as missed', () {
      ScheduleItem skippedWith(String? reason) => ScheduleItem(
        id: 'x',
        targetUid: 'me',
        createdByUid: 'me',
        groupId: '',
        title: 't',
        localWallTime: '',
        timezone: zone,
        scheduledInstantUtc: now,
        status: ScheduleItemStatus.approved,
        outcome: ScheduleOutcome(
          result: OutcomeResult.skipped,
          skipReason: reason,
        ),
      );
      expect(toStatItem(skippedWith(kLapsedSkipReason)).isMissed, isTrue);
      expect(
        toStatItem(skippedWith(kUserUnavailableSkipReason)).isMissed,
        isTrue,
      );
      expect(toStatItem(skippedWith('Clinic closed')).isMissed, isFalse);
      expect(toStatItem(skippedWith(null)).isMissed, isFalse);
    });

    test('the week hero separates done, skipped and missed', () {
      final s = build(
        target: [
          item(at: daysAgo(1), done: true),
          item(at: daysAgo(2), done: true),
          item(at: daysAgo(3), skipped: true),
          item(at: daysAgo(4), missed: true),
        ],
      );
      expect(s.last7.done, 2);
      expect(s.last7.skipped, 1);
      expect(s.last7.missed, 1);
    });

    test('Done (Late) counts as done, not missed', () {
      final s = build(
        target: [item(at: daysAgo(1), done: true, unavailable: true)],
      );
      expect(s.last7.done, 1);
      expect(s.last7.missed, 0);
    });
  });

  group('rolling windows', () {
    test('last 7 vs the 7 before, by scheduled time', () {
      final s = build(
        target: [
          item(at: daysAgo(0, hour: 9), done: true),
          item(at: daysAgo(6), done: true),
          item(at: daysAgo(8), done: true),
          item(at: daysAgo(13), done: true),
          item(at: daysAgo(13), done: true),
          item(at: daysAgo(20), done: true), // outside both windows
        ],
      );
      expect(s.last7.done, 2);
      expect(s.previous7.done, 3);
    });

    test('future plans are in no window', () {
      final s = build(target: [item(at: now.add(const Duration(days: 1)))]);
      expect(s.last7.total, 0);
    });

    test('eight weekly buckets, oldest first, last == last7', () {
      final s = build(
        target: [
          item(at: daysAgo(1), done: true),
          item(at: daysAgo(1), done: true),
          item(at: daysAgo(9), done: true),
          item(at: daysAgo(52), done: true), // week 8 (oldest)
          item(at: daysAgo(60), done: true), // beyond eight weeks
        ],
      );
      expect(s.weeklyDone, hasLength(8));
      expect(s.weeklyDone.last, s.last7.done);
      expect(s.weeklyDone.last, 2);
      expect(s.weeklyDone[6], 1);
      expect(s.weeklyDone.first, 1);
      expect(s.weeklyDone.reduce((a, b) => a + b), 4);
    });
  });

  group('minimum sample', () {
    test('a percentage is null below five answered plans', () {
      final s = build(
        target: [for (var d = 1; d <= 4; d++) item(at: daysAgo(d), done: true)],
      );
      expect(s.followThrough, isNull);
      expect(s.answeredWhenRang, isNull);
    });

    test('five answered plans produce a number', () {
      final s = build(
        target: [
          for (var d = 1; d <= 4; d++) item(at: daysAgo(d), done: true),
          item(at: daysAgo(5), skipped: true),
        ],
      );
      expect(s.followThrough, 80);
    });

    test('upcoming plans never count against follow-through', () {
      final s = build(
        target: [
          for (var d = 1; d <= 5; d++) item(at: daysAgo(d), done: true),
          item(at: now.add(const Duration(days: 2))),
        ],
      );
      expect(s.followThrough, 100);
    });
  });

  group('follow-through and answered-when-it-rang', () {
    test('skips and misses both count against follow-through', () {
      final s = build(
        target: [
          for (var d = 1; d <= 6; d++) item(at: daysAgo(d), done: true),
          item(at: daysAgo(7), skipped: true),
          item(at: daysAgo(8), missed: true),
        ],
      );
      expect(s.followThrough, 75);
    });

    test('answered excludes missed and Done (Late); early answers count', () {
      final s = build(
        target: [
          item(at: daysAgo(1), done: true),
          item(at: daysAgo(2), skipped: true), // deliberate: answered
          item(at: daysAgo(3), done: true, unavailable: true), // Done (Late)
          item(at: daysAgo(4), missed: true),
          item(at: daysAgo(5), done: true),
        ],
      );
      expect(s.answeredWhenRang, 60);
    });

    test('split: set for you vs self-plans', () {
      final s = build(
        target: [
          for (var d = 1; d <= 5; d++)
            item(at: daysAgo(d), done: true, self: false),
          for (var d = 1; d <= 4; d++) item(at: daysAgo(d), done: true),
          item(at: daysAgo(5), missed: true),
        ],
      );
      expect(s.followThroughSetForYou, 100);
      expect(s.followThroughSelf, 80);
      expect(s.followThrough, 90);
    });

    test('cancelled plans count nowhere', () {
      final s = build(
        target: [
          for (var d = 1; d <= 5; d++) item(at: daysAgo(d), done: true),
          item(at: daysAgo(1), cancelled: true, self: false),
        ],
      );
      expect(s.setForYouCount, 0);
      expect(s.followThrough, 100);
    });
  });

  group('humane streak', () {
    Streaks streaks(List<StatItem> items, {String timezone = zone}) =>
        computeStreaks(items, timezone);

    test('neutral gaps, skip-only days and today’s open plans never break', () {
      final s = streaks([
        item(at: daysAgo(0, hour: 20)), // today, still open
        item(at: daysAgo(1), done: true),
        item(at: daysAgo(2), skipped: true), // skip-only: neutral
        // 3 and 4: nothing planned — neutral
        item(at: daysAgo(5), done: true),
      ]);
      expect(s.current, 2);
    });

    test('a missed plan on a done day breaks it', () {
      final s = streaks([
        item(at: daysAgo(1), done: true),
        item(at: daysAgo(2, hour: 9), done: true),
        item(at: daysAgo(2, hour: 18), missed: true),
        item(at: daysAgo(3), done: true),
      ]);
      expect(s.current, 1);
    });

    test('Done (Late) extends — it was answered in the end', () {
      final s = streaks([
        item(at: daysAgo(1), done: true, unavailable: true),
        item(at: daysAgo(2), done: true),
      ]);
      expect(s.current, 2);
    });

    test('best is the longest run in history', () {
      final s = streaks([
        item(at: daysAgo(1), done: true),
        item(at: daysAgo(2), missed: true),
        for (var d = 3; d <= 7; d++) item(at: daysAgo(d), done: true),
        item(at: daysAgo(8), missed: true),
        item(at: daysAgo(9), done: true),
      ]);
      expect(s.current, 1);
      expect(s.best, 5);
    });

    test('a missed most-recent day means current is zero, best survives', () {
      final s = streaks([
        item(at: daysAgo(1), missed: true),
        item(at: daysAgo(2), done: true),
        item(at: daysAgo(3), done: true),
      ]);
      expect(s.current, 0);
      expect(s.best, 2);
    });

    test('cancelled plans are ignored', () {
      final s = streaks([
        item(at: daysAgo(1), done: true),
        item(at: daysAgo(2), missed: true, cancelled: true),
        item(at: daysAgo(3), done: true),
      ]);
      expect(s.current, 2);
    });

    test('DST: a 23-hour local day is still one day (New York spring)', () {
      // 2026-03-08 is spring-forward in New York.
      DateTime ny(int day, int hour) =>
          DateTime.utc(2026, 3, day, hour + 5); // EST offset; close enough
      final s = computeStreaks([
        item(at: ny(7, 12), done: true),
        item(at: ny(8, 12), done: true),
        item(at: ny(9, 12), done: true),
      ], 'America/New_York');
      expect(s.current, 3);
      expect(s.best, 3);
    });

    test('an unknown zone yields zero', () {
      expect(
        streaks([
          item(at: daysAgo(1), done: true),
        ], timezone: 'Not/AZone').current,
        0,
      );
    });
  });

  group('relationships', () {
    test('top planners: most first, ties by uid, at most three', () {
      final s = build(
        target: [
          for (var i = 0; i < 3; i++)
            item(at: daysAgo(i + 1), self: false, creator: 'b'),
          for (var i = 0; i < 2; i++)
            item(at: daysAgo(i + 1), self: false, creator: 'a'),
          item(at: daysAgo(1), self: false, creator: 'd'),
          item(at: daysAgo(1), self: false, creator: 'c'),
          item(at: daysAgo(1), done: true), // self: never a "planner"
        ],
      );
      expect(s.topPlanners.map((p) => p.uid), ['b', 'a', 'c']);
      expect(s.topPlanners.first.count, 3);
      expect(s.setForYouCount, 7);
    });

    test('alarms set for others exclude self and cancelled', () {
      final s = build(
        planner: [
          item(at: daysAgo(1), self: false, done: true),
          item(at: daysAgo(2), self: false, cancelled: true),
          item(at: daysAgo(3), done: true), // self-plan
        ],
      );
      expect(s.alarmsSetCount, 1);
      expect(s.alarmsSetCompletion, isNull); // below the sample
    });

    test('their completion needs five answered', () {
      final s = build(
        planner: [
          for (var d = 1; d <= 3; d++)
            item(at: daysAgo(d), self: false, done: true),
          item(at: daysAgo(4), self: false, missed: true),
          item(at: daysAgo(5), self: false, skipped: true),
        ],
      );
      expect(s.alarmsSetCompletion, 60);
    });

    test('requests fulfilled = my plans for others with a request link', () {
      final s = build(
        planner: [
          item(at: daysAgo(1), self: false, fromRequest: true),
          item(at: daysAgo(2), self: false, fromRequest: true, cancelled: true),
          item(at: daysAgo(3), self: false),
        ],
      );
      expect(s.requestsFulfilled, 1);
    });

    test('my requests: fulfilled out of closed, cancelled excluded', () {
      RequestSummary r({
        bool fulfilled = false,
        bool declined = false,
        bool cancelled = false,
        bool open = false,
        int windowEndDaysAgo = 1,
      }) => RequestSummary(
        fulfilled: fulfilled,
        declined: declined,
        cancelled: cancelled,
        open: open,
        windowEndUtc: now.subtract(Duration(days: windowEndDaysAgo)),
      );
      final s = build(
        requests: [
          r(fulfilled: true),
          r(fulfilled: true),
          r(declined: true),
          r(open: true), // window passed: closed, unanswered
          r(open: true, windowEndDaysAgo: -1), // still open: not counted
          r(cancelled: true),
        ],
      );
      expect(s.requestsAnswered, 2);
      expect(s.requestsClosed, 4);
    });
  });

  test('empty only when there is nothing in either role', () {
    expect(build().isEmpty, isTrue);
    expect(build(planner: [item(at: daysAgo(1), self: false)]).isEmpty, false);
  });
}
