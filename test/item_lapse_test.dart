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

    test('a pending item past its day is to be rejected', () {
      final result = lapsedItems(
        [item(year: 2026, month: 8, day: 26, status: ScheduleItemStatus.pending)],
        now,
      );
      expect(result.toReject, hasLength(1));
      expect(result.toSkip, isEmpty);
    });

    test('an approved outcome-less item past its day is to be skipped', () {
      final result = lapsedItems(
        [item(year: 2026, month: 8, day: 26)],
        now,
      );
      expect(result.toSkip, hasLength(1));
      expect(result.toReject, isEmpty);
    });

    test('already-settled items are never re-touched (idempotent)', () {
      final done = ScheduleOutcome(
        result: OutcomeResult.done,
        completedAt: DateTime.utc(2026, 8, 26, 5),
      );
      final result = lapsedItems(
        [
          item(year: 2026, month: 8, day: 26, outcome: done),
          item(year: 2026, month: 8, day: 26, status: ScheduleItemStatus.rejected),
        ],
        now,
      );
      expect(result.isEmpty, isTrue);
    });

    test('today’s items are left alone until their day ends', () {
      // Item is on 27 Aug; now is midday 27 Aug — still actionable.
      final result = lapsedItems(
        [
          item(year: 2026, month: 8, day: 27, status: ScheduleItemStatus.pending),
          item(year: 2026, month: 8, day: 27),
        ],
        now,
      );
      expect(result.isEmpty, isTrue);
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
}
