import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/features/calendar/application/calendar_grouping.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// The calendar's correctness lives here, for the same reason the reminder
/// layer's does: everything that can be *wrong* about it is a pure function.
///
/// The failure mode this file exists to catch is specifically quiet — an item
/// filed under the wrong day still renders perfectly, on a date nobody looks
/// at. There is no crash and no log line, so a device pass would very likely
/// miss it.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  const kolkata = 'Asia/Kolkata'; // UTC+5:30, no DST
  const chicago = 'America/Chicago'; // UTC-6 / -5, observes DST

  ScheduleItem item({
    required String id,
    required DateTime instantUtc,
    String timezone = kolkata,
    String targetUid = 'me',
    String createdByUid = 'planner',
    String title = 'Item',
    ScheduleItemStatus status = ScheduleItemStatus.approved,
    ScheduleOutcome? outcome,
  }) {
    return ScheduleItem(
      id: id,
      targetUid: targetUid,
      createdByUid: createdByUid,
      groupId: 'g1',
      title: title,
      localWallTime: '',
      timezone: timezone,
      scheduledInstantUtc: instantUtc,
      status: status,
      outcome: outcome,
    );
  }

  group('itemWallTime / calendarDayFor — the item OWNS its day', () {
    test('resolves the instant in the ITEM\'s zone, not the host\'s', () {
      // 2026-08-25 03:30Z is 09:00 the same day in Kolkata (+5:30).
      final it = item(
        id: 'a',
        instantUtc: DateTime.utc(2026, 8, 25, 3, 30),
      );
      expect(itemWallTime(it), DateTime.utc(2026, 8, 25, 9, 0));
      expect(calendarDayFor(it), DateTime.utc(2026, 8, 25));
    });

    test('an instant that crosses midnight lands on the LOCAL day', () {
      // 2026-08-25 20:00Z is 01:30 on the 26th in Kolkata. Bucketing by UTC —
      // or by a Chicago viewer's device zone — would file it a day early, and
      // the card inside the cell would read "Wed" under Tuesday.
      final it = item(
        id: 'b',
        instantUtc: DateTime.utc(2026, 8, 25, 20),
      );
      expect(calendarDayFor(it), DateTime.utc(2026, 8, 26));
      expect(itemWallTime(it).hour, 1);
      expect(itemWallTime(it).minute, 30);
    });

    test('honours a DST offset rather than a fixed one', () {
      // Chicago is UTC-5 in August (CDT) and UTC-6 in January (CST). The same
      // 04:00Z lands on different local days in the two months, which a fixed
      // offset would get right in at most one of them.
      final summer = item(
        id: 'c',
        instantUtc: DateTime.utc(2026, 8, 25, 4),
        timezone: chicago,
      );
      final winter = item(
        id: 'd',
        instantUtc: DateTime.utc(2026, 1, 25, 4),
        timezone: chicago,
      );
      expect(itemWallTime(summer).hour, 23); // 23:00 on the 24th, CDT
      expect(calendarDayFor(summer), DateTime.utc(2026, 8, 24));
      expect(itemWallTime(winter).hour, 22); // 22:00 on the 24th, CST
      expect(calendarDayFor(winter), DateTime.utc(2026, 1, 24));
    });

    test('an unknown zone falls back instead of throwing', () {
      // A malformed document must not take the whole grid down. It gets a
      // plausible cell rather than vanishing.
      final it = item(
        id: 'e',
        instantUtc: DateTime.utc(2026, 8, 25, 12),
        timezone: 'Not/AZone',
      );
      expect(() => calendarDayFor(it), returnsNormally);
      expect(calendarDayFor(it).isUtc, isTrue);
    });

    test('an empty zone falls back too', () {
      final it = item(
        id: 'f',
        instantUtc: DateTime.utc(2026, 8, 25, 12),
        timezone: '',
      );
      expect(() => itemWallTime(it), returnsNormally);
    });

    test('day keys are UTC midnight, so they compare as map keys', () {
      final key = calendarDayFor(
        item(id: 'g', instantUtc: DateTime.utc(2026, 8, 25, 3, 30)),
      );
      expect(key.isUtc, isTrue);
      expect(key.hour, 0);
      expect(key, calendarDayKey(DateTime.utc(2026, 8, 25, 17, 45)));
      expect({key: 1}[DateTime.utc(2026, 8, 25)], 1);
    });
  });

  group('calendarEntries — merging the two roles', () {
    test('labels each side from the viewer\'s position', () {
      final mine = item(
        id: 'mine',
        instantUtc: DateTime.utc(2026, 8, 25, 3),
        targetUid: 'me',
        createdByUid: 'friend',
      );
      final theirs = item(
        id: 'theirs',
        instantUtc: DateTime.utc(2026, 8, 25, 4),
        targetUid: 'friend',
        createdByUid: 'me',
      );

      final entries = calendarEntries(
        asTarget: [mine],
        asPlanner: [theirs],
        viewerUid: 'me',
      );

      expect(entries.map((e) => e.item.id), ['mine', 'theirs']);
      expect(entries.first.side, CalendarSide.mine);
      expect(entries.last.side, CalendarSide.planned);
    });

    test('a self-planned item appears ONCE, on the target side', () {
      // The user is creator AND target, so this document is in both streams —
      // the same duplication `archivedItemsProvider` already has to dedup. It
      // is the user's own schedule, so it must not read as "planned for
      // someone".
      final self = item(
        id: 'self',
        instantUtc: DateTime.utc(2026, 8, 25, 3),
        targetUid: 'me',
        createdByUid: 'me',
      );

      final entries = calendarEntries(
        asTarget: [self],
        asPlanner: [self],
        viewerUid: 'me',
      );

      expect(entries, hasLength(1));
      expect(entries.single.side, CalendarSide.mine);
    });

    test('signed out yields an empty calendar, not mislabelled entries', () {
      final entries = calendarEntries(
        asTarget: [item(id: 'a', instantUtc: DateTime.utc(2026, 8, 25, 3))],
        asPlanner: const [],
        viewerUid: null,
      );
      expect(entries, isEmpty);
    });

    test('order is stable when two items share an instant', () {
      // Firestore emits in its own order, so without the title/id tiebreak two
      // items at the same minute would swap places on every stream emission.
      final at = DateTime.utc(2026, 8, 25, 3);
      final forward = calendarEntries(
        asTarget: [
          item(id: 'z', instantUtc: at, title: 'Zebra'),
          item(id: 'a', instantUtc: at, title: 'Apple'),
        ],
        asPlanner: const [],
        viewerUid: 'me',
      );
      final backward = calendarEntries(
        asTarget: [
          item(id: 'a', instantUtc: at, title: 'Apple'),
          item(id: 'z', instantUtc: at, title: 'Zebra'),
        ],
        asPlanner: const [],
        viewerUid: 'me',
      );
      expect(forward.map((e) => e.item.id), backward.map((e) => e.item.id));
      expect(forward.map((e) => e.item.id), ['a', 'z']);
    });

    test('every status is plotted — the calendar filters nothing itself', () {
      // Hiding is `schedule_providers`' job and is applied in exactly one
      // place. A second filter here would be a second thing to keep in step.
      final entries = calendarEntries(
        asTarget: [
          for (final status in ScheduleItemStatus.values)
            item(
              id: status.name,
              instantUtc: DateTime.utc(2026, 8, 25, 3),
              status: status,
            ),
        ],
        asPlanner: const [],
        viewerUid: 'me',
      );
      expect(entries, hasLength(ScheduleItemStatus.values.length));
    });
  });

  group('grouping and the day rail', () {
    List<CalendarEntry> entriesFor(List<ScheduleItem> items) =>
        calendarEntries(asTarget: items, asPlanner: const [], viewerUid: 'me');

    test('groups by day and sorts within a day', () {
      final byDay = groupEntriesByDay(entriesFor([
        item(id: 'late', instantUtc: DateTime.utc(2026, 8, 25, 10)), // 15:30
        item(id: 'early', instantUtc: DateTime.utc(2026, 8, 25, 3)), // 08:30
        item(id: 'next', instantUtc: DateTime.utc(2026, 8, 26, 3)),
      ]));

      expect(byDay.keys, hasLength(2));
      expect(
        byDay[DateTime.utc(2026, 8, 25)]!.map((e) => e.item.id),
        ['early', 'late'],
      );
    });

    test('entriesOn tolerates any DateTime, and a free day is empty', () {
      final byDay = groupEntriesByDay(entriesFor([
        item(id: 'a', instantUtc: DateTime.utc(2026, 8, 25, 3)),
      ]));
      // A non-normalized argument still resolves — callers pass whatever the
      // grid handed them.
      expect(entriesOn(byDay, DateTime.utc(2026, 8, 25, 19, 12)), hasLength(1));
      expect(entriesOn(byDay, DateTime.utc(2026, 8, 26)), isEmpty);
    });

    test('groupEntriesByHour keys on the hour PRINTED on the card', () {
      final byHour = groupEntriesByHour(entriesFor([
        item(id: 'a', instantUtc: DateTime.utc(2026, 8, 25, 3, 30)), // 09:00
        item(id: 'b', instantUtc: DateTime.utc(2026, 8, 25, 3, 45)), // 09:15
        item(id: 'c', instantUtc: DateTime.utc(2026, 8, 25, 13, 30)), // 19:00
      ]));

      expect(byHour.keys.toSet(), {9, 19});
      expect(byHour[9]!.map((e) => e.item.id), ['a', 'b']);
    });

    test('openingHourFor prefers the first item over the clock', () {
      final entries = entriesFor([
        item(id: 'a', instantUtc: DateTime.utc(2026, 8, 25, 3, 30)), // 09:00
      ]);
      expect(
        openingHourFor(entries: entries, isToday: true, nowHour: 15),
        9,
      );
    });

    test('a free day opens on now only when it IS today', () {
      expect(
        openingHourFor(entries: const [], isToday: true, nowHour: 15),
        15,
      );
      // Scrolling a future Saturday to 3pm because that is what time it is now
      // would be noise.
      expect(
        openingHourFor(entries: const [], isToday: false, nowHour: 15),
        8,
      );
    });
  });
}
