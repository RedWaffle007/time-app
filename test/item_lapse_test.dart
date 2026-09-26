import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/scheduling/application/item_lapse_policy.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// The end-of-day lapse rule — pure, so it needs no device or clock of its own.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  const zone = 'Asia/Karachi'; // UTC+5, no DST — a clean local day boundary.

  ScheduleItem item({
    required int year,
    required int month,
    required int day,
    int hour = 9,
    ScheduleItemStatus status = ScheduleItemStatus.approved,
    ScheduleOutcome? outcome,
    String tz = zone,
  }) {
    // Karachi is UTC+5, so the instant is the wall time minus five hours.
    final utc = DateTime.utc(year, month, day, hour - 5);
    return ScheduleItem(
      id: '$year-$month-$day-$hour',
      targetUid: 't',
      createdByUid: 'p',
      groupId: 'g',
      title: 'x',
      localWallTime: '',
      timezone: tz,
      scheduledInstantUtc: utc,
      status: status,
      outcome: outcome,
    );
  }

  group('endOfScheduledLocalDayUtc', () {
    test('is the next local midnight in the item’s own zone', () {
      final i = item(year: 2026, month: 8, day: 26, hour: 9);
      // Next local midnight = 27 Aug 00:00 Karachi = 26 Aug 19:00 UTC.
      expect(endOfScheduledLocalDayUtc(i), DateTime.utc(2026, 8, 26, 19));
    });
  });

  group('hasLapsed', () {
    final i = item(year: 2026, month: 8, day: 26, hour: 9);
    test('not lapsed later the same local day', () {
      // 26 Aug 23:59 Karachi = 26 Aug 18:59 UTC — still that day.
      expect(hasLapsed(i, DateTime.utc(2026, 8, 26, 18, 59)), isFalse);
    });
    test('lapses once its local day has ended', () {
      // 27 Aug 00:00 Karachi = 26 Aug 19:00 UTC.
      expect(hasLapsed(i, DateTime.utc(2026, 8, 26, 19)), isTrue);
    });
  });

  group('lapsedItems', () {
    // "Now" is 27 Aug ~12:00 Karachi — the day after the items below.
    final now = DateTime.utc(2026, 8, 27, 7);

    // F2: a pending item can only be a legacy plan; it is never rejected.
    test('a legacy pending item past its day is approved and skipped', () {
      final result = lapsedItems([
        item(year: 2026, month: 8, day: 26, status: ScheduleItemStatus.pending),
      ], now);
      expect(result.toApproveAndSkip, hasLength(1));
      expect(result.toApprove, isEmpty);
      expect(result.toSkip, isEmpty);
    });

    test('a legacy pending item before its deadline becomes an alarm', () {
      final result = lapsedItems([
        item(year: 2026, month: 8, day: 28, status: ScheduleItemStatus.pending),
      ], now);
      expect(result.toApprove, hasLength(1));
      expect(result.toApproveAndSkip, isEmpty);
    });

    test('an approved outcome-less item past its day is to be skipped', () {
      final result = lapsedItems([item(year: 2026, month: 8, day: 26)], now);
      expect(result.toSkip, hasLength(1));
      expect(result.toApproveAndSkip, isEmpty);
    });

    test('already-settled items are never re-touched (idempotent)', () {
      final done = ScheduleOutcome(
        result: OutcomeResult.done,
        completedAt: DateTime.utc(2026, 8, 26, 5),
      );
      final result = lapsedItems([
        item(year: 2026, month: 8, day: 26, outcome: done),
        item(
          year: 2026,
          month: 8,
          day: 26,
          status: ScheduleItemStatus.rejected,
        ),
      ], now);
      expect(result.isEmpty, isTrue);
    });

    test('today’s items are left alone until their day ends', () {
      // Item is on 27 Aug; now is midday 27 Aug — still actionable.
      final result = lapsedItems([
        item(year: 2026, month: 8, day: 27, status: ScheduleItemStatus.pending),
        item(year: 2026, month: 8, day: 27),
      ], now);
      // Nothing is settled; the legacy pending one just becomes an alarm (F2).
      expect(result.toSkip, isEmpty);
      expect(result.toApproveAndSkip, isEmpty);
      expect(result.toApprove, hasLength(1));
    });
  });

  group('completionDelay (late completions are honest data)', () {
    test('done after the scheduled time reports the delay', () {
      final scheduled = DateTime.utc(2026, 8, 26, 4); // 09:00 Karachi
      final i = ScheduleItem(
        id: '1',
        targetUid: 't',
        createdByUid: 'p',
        groupId: 'g',
        title: 'x',
        localWallTime: '',
        timezone: zone,
        scheduledInstantUtc: scheduled,
        status: ScheduleItemStatus.approved,
        outcome: ScheduleOutcome(
          result: OutcomeResult.done,
          completedAt: scheduled.add(const Duration(hours: 2, minutes: 15)),
        ),
      );
      expect(i.wasCompletedLate, isTrue);
      expect(i.completionDelay, const Duration(hours: 2, minutes: 15));
    });

    test('done on time reports no delay', () {
      final scheduled = DateTime.utc(2026, 8, 26, 4);
      final i = ScheduleItem(
        id: '2',
        targetUid: 't',
        createdByUid: 'p',
        groupId: 'g',
        title: 'x',
        localWallTime: '',
        timezone: zone,
        scheduledInstantUtc: scheduled,
        status: ScheduleItemStatus.approved,
        outcome: ScheduleOutcome(
          result: OutcomeResult.done,
          completedAt: scheduled.subtract(const Duration(minutes: 5)),
        ),
      );
      expect(i.wasCompletedLate, isFalse);
      expect(i.completionDelay, isNull);
    });
  });

  group('sanitizeScheduleTitle', () {
    test('drops dotted meridian residue anywhere', () {
      expect(sanitizeScheduleTitle('a.m. cycling'), 'cycling');
      expect(sanitizeScheduleTitle('cycling p.m.'), 'cycling');
    });
    test('drops a bare meridian only at the edges', () {
      expect(sanitizeScheduleTitle('am cycling'), 'cycling');
      expect(sanitizeScheduleTitle('cycling pm'), 'cycling');
    });
    test('keeps an interior real word', () {
      expect(sanitizeScheduleTitle('I am tired'), 'I am tired');
      expect(sanitizeScheduleTitle('check spam folder'), 'check spam folder');
    });
    test('never empties the title', () {
      expect(sanitizeScheduleTitle('a.m.'), 'a.m.');
    });
  });

  // Item 19 (2026-09-26): nobody gets less than two hours to respond. The
  // deadline is the LATER of local midnight and scheduled time + 2 h.
  group('responseDeadlineUtc — two-hour minimum near midnight', () {
    ScheduleItem at(String zone, DateTime utc, {ScheduleItemStatus? status}) =>
        ScheduleItem(
          id: '${zone}_${utc.toIso8601String()}',
          targetUid: 't',
          createdByUid: 'p',
          groupId: 'g',
          title: 'x',
          localWallTime: '',
          timezone: zone,
          scheduledInstantUtc: utc,
          status: status ?? ScheduleItemStatus.approved,
        );
    // Karachi local wall time → UTC (UTC+5, no DST).
    DateTime khi(int day, int hour, [int minute = 0]) =>
        DateTime.utc(2026, 8, day, hour - 5, minute);
    final midnight = DateTime.utc(2026, 8, 26, 19); // 27 Aug 00:00 Karachi

    test('earlier tasks keep the end-of-day deadline', () {
      for (final (h, m) in [(9, 0), (18, 0), (21, 59)]) {
        expect(
          responseDeadlineUtc(at(zone, khi(26, h, m))),
          midnight,
          reason: '$h:$m',
        );
      }
    });

    test('exactly 22:00 is both rules at once — still midnight', () {
      expect(responseDeadlineUtc(at(zone, khi(26, 22))), midnight);
    });

    test('after 22:00 the deadline is exactly two hours on', () {
      expect(
        responseDeadlineUtc(at(zone, khi(26, 22, 30))),
        midnight.add(const Duration(minutes: 30)),
      );
      expect(
        responseDeadlineUtc(at(zone, khi(26, 23, 50))),
        midnight.add(const Duration(hours: 1, minutes: 50)),
      );
    });

    test('a 23:50 task is still actionable after midnight until 01:50', () {
      final i = at(zone, khi(26, 23, 50));
      expect(hasLapsed(i, midnight), isFalse);
      expect(
        hasLapsed(i, midnight.add(const Duration(hours: 1, minutes: 49))),
        isFalse,
      );
      expect(
        hasLapsed(i, midnight.add(const Duration(hours: 1, minutes: 50))),
        isTrue,
      );
    });

    test('both lapses use the same deadline', () {
      final pending = at(
        zone,
        khi(26, 23, 30),
        status: ScheduleItemStatus.pending,
      );
      final approved = at(zone, khi(26, 23, 30));
      final early = lapsedItems([
        pending,
        approved,
      ], midnight.add(const Duration(minutes: 30)));
      // Before the deadline the legacy pending plan just becomes an alarm.
      expect(early.toApprove.map((e) => e.id), [pending.id]);
      expect(early.toApproveAndSkip, isEmpty);
      expect(early.toSkip, isEmpty);
      final late = lapsedItems([
        pending,
        approved,
      ], midnight.add(const Duration(hours: 1, minutes: 30)));
      expect(late.toApproveAndSkip.map((e) => e.id), [pending.id]);
      expect(late.toSkip.map((e) => e.id), [approved.id]);
    });

    test('two real hours across a DST spring-forward night', () {
      // New York, 7 Mar 2026 23:00 EST = 8 Mar 04:00 UTC. Clocks jump at 02:00.
      final i = at('America/New_York', DateTime.utc(2026, 3, 8, 4));
      expect(responseDeadlineUtc(i), DateTime.utc(2026, 3, 8, 6));
    });

    test('two real hours across a DST fall-back night', () {
      // New York, 31 Oct 2026 23:30 EDT = 1 Nov 03:30 UTC. Midnight EDT is
      // 04:00 UTC; the two-hour minimum (05:30 UTC) wins.
      final i = at('America/New_York', DateTime.utc(2026, 11, 1, 3, 30));
      expect(responseDeadlineUtc(i), DateTime.utc(2026, 11, 1, 5, 30));
    });

    test('a quarter-hour zone uses its own midnight', () {
      // Kathmandu UTC+05:45: 23:00 local = 17:15 UTC; midnight = 18:15 UTC.
      final i = at('Asia/Kathmandu', DateTime.utc(2026, 8, 26, 17, 15));
      expect(responseDeadlineUtc(i), DateTime.utc(2026, 8, 26, 19, 15));
    });

    test('invariants at every minute of a local day', () {
      for (var minute = 0; minute < 24 * 60; minute++) {
        final scheduled = khi(26, 0).add(Duration(minutes: minute));
        final i = at(zone, scheduled);
        final deadline = responseDeadlineUtc(i);
        final floor = scheduled.add(kMinResponseWindow);
        expect(deadline.isBefore(floor), isFalse, reason: '$minute');
        expect(deadline.isBefore(endOfScheduledLocalDayUtc(i)), isFalse);
        expect(
          deadline == floor || deadline == endOfScheduledLocalDayUtc(i),
          isTrue,
        );
        // Never later than two hours past that day's end.
        expect(deadline.isAfter(midnight.add(kMinResponseWindow)), isFalse);
      }
    });
  });
}
