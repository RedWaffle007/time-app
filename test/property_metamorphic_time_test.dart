import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:time_app/core/timezone/quiet_hours.dart';
import 'package:time_app/core/timezone/tz_resolver.dart';
import 'package:time_app/features/calendar/application/calendar_grouping.dart';
import 'package:time_app/features/scheduling/application/item_lapse_policy.dart';
import 'package:time_app/features/scheduling/application/slot_availability.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/domain/slot.dart';

ScheduleItem _item({
  required String id,
  required DateTime at,
  String zone = 'UTC',
  String target = 'me',
  String creator = 'planner',
  ScheduleItemStatus status = ScheduleItemStatus.approved,
  ScheduleOutcome? outcome,
}) => ScheduleItem(
  id: id,
  targetUid: target,
  createdByUid: creator,
  groupId: 'g',
  title: 'item-$id',
  localWallTime: '',
  timezone: zone,
  scheduledInstantUtc: at,
  status: status,
  outcome: outcome,
);

DateTime _renderWall(DateTime instant, String zone) {
  final local = tz.TZDateTime.from(instant, tz.getLocation(zone));
  return DateTime.utc(
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute,
  );
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('resolveWall metamorphic relations', () {
    const zones = [
      'UTC',
      'Asia/Kolkata',
      'Asia/Kathmandu',
      'America/New_York',
      'Europe/London',
      'Australia/Sydney',
    ];

    test('resolve-render-resolve is idempotent for real wall times', () {
      for (final zone in zones) {
        for (var month = 1; month <= 12; month++) {
          for (final hour in [0, 6, 12, 18]) {
            final wall = DateTime.utc(2026, month, 15, hour, 17);
            final first = resolveWall(wall, zone);
            final second = resolveWall(_renderWall(first.utc, zone), zone);
            expect(second.utc, first.utc, reason: '$zone $wall');
            expect(second.anomaly, DstAnomaly.none, reason: '$zone $wall');
          }
        }
      }
    });

    test('+24h wall shift equals 24h adjusted by the offset change', () {
      for (final zone in zones) {
        final location = tz.getLocation(zone);
        for (var day = 1; day <= 365; day += 3) {
          final wall = DateTime.utc(
            2026,
            1,
            1,
            12,
          ).add(Duration(days: day - 1));
          final nextWall = wall.add(const Duration(days: 1));
          final a = resolveWall(wall, zone);
          final b = resolveWall(nextWall, zone);
          final offsetA = location
              .timeZone(a.utc.millisecondsSinceEpoch)
              .offset;
          final offsetB = location
              .timeZone(b.utc.millisecondsSinceEpoch)
              .offset;
          expect(
            b.utc.difference(a.utc),
            const Duration(days: 1) - (offsetB - offsetA),
            reason: '$zone $wall offsets $offsetA -> $offsetB',
          );
        }
      }
    });

    test('spring gaps preserve minutes while pushing by exactly the gap', () {
      final cases = [
        ('America/New_York', DateTime.utc(2026, 3, 8, 2, 0), 60),
        ('Europe/London', DateTime.utc(2026, 3, 29, 1, 0), 60),
        ('Australia/Sydney', DateTime.utc(2026, 10, 4, 2, 0), 60),
      ];
      for (final (zone, gapStart, gapMinutes) in cases) {
        for (var minute = 0; minute < gapMinutes; minute += 7) {
          final wall = gapStart.add(Duration(minutes: minute));
          final resolved = resolveWall(wall, zone);
          expect(resolved.anomaly, DstAnomaly.skipped, reason: '$zone $wall');
          expect(
            _renderWall(resolved.utc, zone),
            wall.add(Duration(minutes: gapMinutes)),
            reason: '$zone $wall',
          );
        }
      }
    });

    test('fall overlaps choose the earlier of both valid occurrences', () {
      final cases = [
        ('America/New_York', DateTime.utc(2026, 11, 1, 1, 0)),
        ('Europe/London', DateTime.utc(2026, 10, 25, 1, 0)),
        ('Australia/Sydney', DateTime.utc(2026, 4, 5, 2, 0)),
      ];
      for (final (zone, overlapStart) in cases) {
        for (var minute = 0; minute < 60; minute += 11) {
          final wall = overlapStart.add(Duration(minutes: minute));
          final resolved = resolveWall(wall, zone);
          expect(resolved.anomaly, DstAnomaly.ambiguous, reason: '$zone $wall');
          expect(_renderWall(resolved.utc, zone), wall);
          expect(
            _renderWall(resolved.utc.add(const Duration(hours: 1)), zone),
            wall,
          );
        }
      }
    });
  });

  group('quiet-hours algebra', () {
    test('rotation of the clock preserves membership', () {
      const day = 24 * 60;
      for (var minute = 0; minute < day; minute += 17) {
        for (var start = 0; start < day; start += 137) {
          for (final width in [0, 1, 90, 480, 900, 1439]) {
            final end = (start + width) % day;
            final original = minuteInWindow(minute, start, end);
            for (final shift in [1, 59, 720, 1439]) {
              expect(
                minuteInWindow(
                  (minute + shift) % day,
                  (start + shift) % day,
                  (end + shift) % day,
                ),
                original,
                reason: 'minute=$minute [$start,$end) shift=$shift',
              );
            }
          }
        }
      }
    });

    test('a non-empty window and its reverse partition all minutes', () {
      for (var start = 0; start < 1440; start += 113) {
        for (var end = 0; end < 1440; end += 127) {
          if (start == end) continue;
          for (var minute = 0; minute < 1440; minute++) {
            expect(
              minuteInWindow(minute, start, end) ^
                  minuteInWindow(minute, end, start),
              isTrue,
              reason: 'minute=$minute endpoints=$start/$end',
            );
          }
        }
      }
    });
  });

  group('scheduling and calendar generated invariants', () {
    test('slot index/start form a total partition, including pre-epoch', () {
      final random = math.Random(4170);
      for (var n = 0; n < 1000; n++) {
        final ms = random.nextInt(4000000000) - 2000000000;
        final instant = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
        final index = slotIndexFor(instant);
        expect(!instant.isBefore(slotStartUtc(index)), isTrue);
        expect(instant.isBefore(slotEndUtc(index)), isTrue);
        expect(slotEndUtc(index), slotStartUtc(index + 1));
      }
    });

    test('adding settled items never reduces scheduling capacity', () {
      final now = DateTime.utc(2026, 8, 25);
      final base = DateTime.utc(2026, 8, 25, 12);
      final live = <ScheduleItem>[];
      final settled = <ScheduleItem>[];
      for (var i = 0; i < 48; i++) {
        final at = base.add(Duration(minutes: i * 15));
        (i.isEven ? live : settled).add(
          _item(
            id: '$i',
            at: at,
            status: i.isEven
                ? ScheduleItemStatus.pending
                : ScheduleItemStatus.rejected,
          ),
        );
      }
      final before = slotsForLocalDay(
        localDay: now,
        timezone: 'UTC',
        items: live,
        now: now.subtract(const Duration(days: 1)),
      );
      final after = slotsForLocalDay(
        localDay: now,
        timezone: 'UTC',
        items: [...live, ...settled],
        now: now.subtract(const Duration(days: 1)),
      );
      expect(
        after.where((s) => s.isSelectable).length,
        before.where((s) => s.isSelectable).length,
      );
      expect(
        after.map((s) => s.occupants.length),
        before.map((s) => s.occupants.length),
      );
    });

    test('calendar grouping is a lossless, disjoint partition', () {
      final random = math.Random(3630);
      final target = <ScheduleItem>[];
      final planner = <ScheduleItem>[];
      for (var i = 0; i < 250; i++) {
        final entry = _item(
          id: 'id-$i',
          at: DateTime.utc(
            2026,
            1,
            1,
          ).add(Duration(minutes: random.nextInt(525600))),
          zone: ['UTC', 'Asia/Kolkata', 'America/New_York'][i % 3],
        );
        (i.isEven ? target : planner).add(entry);
        if (i % 11 == 0) planner.add(entry); // exercise cross-stream dedup.
      }
      final entries = calendarEntries(
        asTarget: target,
        asPlanner: planner,
        viewerUid: 'me',
      );
      final grouped = groupEntriesByDay(entries);
      final flattened = grouped.values.expand((e) => e).toList();
      expect(flattened, hasLength(entries.length));
      expect(
        flattened.map((e) => e.item.id).toSet(),
        entries.map((e) => e.item.id).toSet(),
      );
      for (final group in grouped.entries) {
        expect(group.value.every((entry) => entry.day == group.key), isTrue);
      }
    });

    test('lapse classification is monotone in time and disjoint', () {
      final items = <ScheduleItem>[];
      for (var day = 1; day <= 20; day++) {
        for (final status in ScheduleItemStatus.values) {
          items.add(
            _item(
              id: '$day-${status.name}',
              at: DateTime.utc(2026, 8, day, 12),
              status: status,
            ),
          );
        }
      }
      Set<String> dueAt(DateTime now) {
        final due = lapsedItems(items, now);
        expect(
          due.toReject
              .map((e) => e.id)
              .toSet()
              .intersection(due.toSkip.map((e) => e.id).toSet()),
          isEmpty,
        );
        return {
          ...due.toReject.map((e) => e.id),
          ...due.toSkip.map((e) => e.id),
        };
      }

      var previous = <String>{};
      for (var day = 1; day <= 25; day++) {
        final current = dueAt(DateTime.utc(2026, 8, day));
        expect(current.containsAll(previous), isTrue, reason: 'day $day');
        previous = current;
      }
    });
  });
}
