import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/features/scheduling/application/slot_availability.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/domain/slot.dart';

/// The slot grid, the conflict rule, and the access mirror's rule.
///
/// These are the parts that can be silently wrong: a slot key that is ambiguous
/// across a DST boundary double-books a target with no error anywhere, and a
/// mirror rule that keeps a row after a revoke leaves someone reading a schedule
/// they were cut off from. Neither shows up as a crash.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  const kolkata = 'Asia/Kolkata'; // +05:30, no DST
  const chicago = 'America/Chicago'; // DST: 2026-03-08 spring forward
  const kathmandu = 'Asia/Kathmandu'; // +05:45 — the awkward one

  ScheduleItem item({
    String id = 'i1',
    required DateTime instantUtc,
    String timezone = kolkata,
    ScheduleItemStatus status = ScheduleItemStatus.approved,
    ScheduleOutcome? outcome,
  }) => ScheduleItem(
    id: id,
    targetUid: 'B',
    createdByUid: 'A',
    groupId: 'g',
    title: 'Gym',
    localWallTime: '',
    timezone: timezone,
    scheduledInstantUtc: instantUtc,
    status: status,
    outcome: outcome,
  );

  group('the slot grid', () {
    test('is 30 minutes and anchored to the epoch', () {
      expect(kSlotMinutes, 30);
      expect(slotIndexFor(DateTime.utc(1970, 1, 1, 0, 0)), 0);
      expect(slotIndexFor(DateTime.utc(1970, 1, 1, 0, 29, 59)), 0);
      expect(slotIndexFor(DateTime.utc(1970, 1, 1, 0, 30)), 1);
    });

    test('is a half-open interval — the end instant is the NEXT slot', () {
      final i = slotIndexFor(DateTime.utc(2026, 8, 25, 16));
      expect(slotStartUtc(i), DateTime.utc(2026, 8, 25, 16));
      expect(slotEndUtc(i), DateTime.utc(2026, 8, 25, 16, 30));
      expect(slotIndexFor(slotEndUtc(i)), i + 1);
    });

    test('floors rather than truncating, so pre-epoch does not skew', () {
      // `~/` rounds toward zero, which would put this instant one bucket LATE.
      expect(slotIndexFor(DateTime.utc(1969, 12, 31, 23, 45)), -1);
      expect(slotStartUtc(-1), DateTime.utc(1969, 12, 31, 23, 30));
    });

    test('lock ids round-trip', () {
      final i = slotIndexFor(DateTime.utc(2026, 8, 25, 16, 15));
      expect(slotLockId(i), i.toString());
      expect(int.parse(slotLockId(i)), i);
    });

    test('a UTC anchor stays unambiguous across a fall-back boundary', () {
      // The whole reason the grid is not anchored to the target's wall clock:
      // on 2026-11-01 Chicago's local 01:30 happens twice. Two DIFFERENT
      // instants must never share a slot key, or one booking would silently
      // block the other.
      final firstPass = DateTime.utc(2026, 11, 1, 6, 30); // 01:30 CDT
      final secondPass = DateTime.utc(2026, 11, 1, 7, 30); // 01:30 CST
      expect(slotIndexFor(firstPass), isNot(slotIndexFor(secondPass)));
    });
  });

  group('what appears on the schedule', () {
    test('pending and approved appear; nothing else does', () {
      expect(
        blocksSlot(
          item(
            instantUtc: DateTime.utc(2026, 8, 25, 16),
            status: ScheduleItemStatus.pending,
          ),
        ),
        isTrue,
      );
      expect(
        blocksSlot(
          item(
            instantUtc: DateTime.utc(2026, 8, 25, 16),
            status: ScheduleItemStatus.approved,
          ),
        ),
        isTrue,
      );
      for (final dead in [
        ScheduleItemStatus.rejected,
        ScheduleItemStatus.withdrawn,
        ScheduleItemStatus.cancelled,
      ]) {
        expect(
          blocksSlot(
            item(instantUtc: DateTime.utc(2026, 8, 25, 16), status: dead),
          ),
          isFalse,
          reason: '$dead is dead and cannot hold a slot',
        );
      }
    });

    test('a recorded outcome releases the claim', () {
      expect(
        blocksSlot(
          item(
            instantUtc: DateTime.utc(2026, 8, 25, 16),
            outcome: const ScheduleOutcome(result: OutcomeResult.done),
          ),
        ),
        isFalse,
      );
    });

    test('a pending plan is visible but does not block another plan', () {
      final slots = slotsForLocalDay(
        localDay: DateTime.utc(2026, 8, 25),
        timezone: kolkata,
        items: [
          item(
            instantUtc: DateTime.utc(2026, 8, 25, 10, 30), // 16:00 IST
            status: ScheduleItemStatus.pending,
          ),
        ],
        now: DateTime.utc(2026, 8, 25, 0),
      );
      final at16 = slots.firstWhere(
        (s) => s.index == slotIndexFor(DateTime.utc(2026, 8, 25, 10, 30)),
      );
      expect(at16.occupants, hasLength(1));
      expect(at16.isBlocked, isFalse);
      expect(at16.isSelectable, isTrue);
    });
  });

  group('slotsForLocalDay', () {
    test('covers a normal day with 48 slots', () {
      final slots = slotsForLocalDay(
        localDay: DateTime.utc(2026, 8, 25),
        timezone: kolkata,
        items: const [],
        now: DateTime.utc(2026, 8, 24),
      );
      expect(slots, hasLength(48));
      expect(slots.every((s) => s.isSelectable), isTrue);
    });

    test('a spring-forward day is genuinely SHORTER, not an assumed 48', () {
      // 2026-03-08 in Chicago is 23 hours long. A hardcoded 48 would invent an
      // hour that does not exist and offer it as bookable.
      final slots = slotsForLocalDay(
        localDay: DateTime.utc(2026, 3, 8),
        timezone: chicago,
        items: const [],
        now: DateTime.utc(2026, 3, 1),
      );
      expect(slots, hasLength(46));
    });

    test('a :45-offset zone still tiles the day completely', () {
      // Kathmandu buckets begin at :15/:45 local — the documented cost of the
      // UTC anchor. What must NOT happen is a gap or an overlap.
      final slots = slotsForLocalDay(
        localDay: DateTime.utc(2026, 8, 25),
        timezone: kathmandu,
        items: const [],
        now: DateTime.utc(2026, 8, 24),
      );
      for (var i = 1; i < slots.length; i++) {
        expect(
          slots[i].startUtc,
          slots[i - 1].endUtc,
          reason: 'slots must tile without gaps',
        );
      }
    });

    test('slots already begun are unselectable but not blocked', () {
      final slots = slotsForLocalDay(
        localDay: DateTime.utc(2026, 8, 25),
        timezone: kolkata,
        items: const [],
        // 12:00 IST
        now: DateTime.utc(2026, 8, 25, 6, 30),
      );
      final past = slots.first;
      expect(past.isPast, isTrue);
      expect(past.isBlocked, isFalse, reason: 'nothing occupies it');
      expect(past.isSelectable, isFalse);
    });

    test('an item in another zone still lands on the right bucket', () {
      // Conflicts are about the target's real time, not about whose zone the
      // item was authored in.
      final instant = DateTime.utc(2026, 8, 25, 10, 30);
      final slots = slotsForLocalDay(
        localDay: DateTime.utc(2026, 8, 25),
        timezone: kolkata,
        items: [item(instantUtc: instant, timezone: chicago)],
        now: DateTime.utc(2026, 8, 25, 0),
      );
      expect(slots.where((s) => s.occupants.isNotEmpty).map((s) => s.index), [
        slotIndexFor(instant),
      ]);
    });
  });

  group('nextFreeSlot', () {
    test('existing plans do not make a future slot unavailable', () {
      final busy = DateTime.utc(2026, 8, 25, 10, 30);
      final slots = slotsForLocalDay(
        localDay: DateTime.utc(2026, 8, 25),
        timezone: kolkata,
        items: [item(instantUtc: busy)],
        now: busy.subtract(const Duration(minutes: 1)),
      );
      final next = nextFreeSlot(slots);
      expect(next, isNotNull);
      expect(next!.isSelectable, isTrue);
      expect(next.index, slotIndexFor(busy));
    });

    test('returns null when the whole day is gone', () {
      final slots = slotsForLocalDay(
        localDay: DateTime.utc(2026, 8, 25),
        timezone: kolkata,
        items: const [],
        now: DateTime.utc(2026, 8, 26),
      );
      expect(nextFreeSlot(slots), isNull);
    });
  });

  group('isInstantBookable — the pre-submit re-check', () {
    final now = DateTime.utc(2026, 8, 25, 6);

    test('free future instant is bookable', () {
      expect(
        isInstantBookable(
          instantUtc: DateTime.utc(2026, 8, 25, 10, 30),
          items: const [],
          now: now,
        ),
        isTrue,
      );
    });

    test('another item in the same bucket does not block it', () {
      expect(
        isInstantBookable(
          instantUtc: DateTime.utc(2026, 8, 25, 10, 45),
          items: [item(instantUtc: DateTime.utc(2026, 8, 25, 10, 30))],
          now: now,
        ),
        isTrue,
      );
    });

    test('the next bucket along is still free', () {
      expect(
        isInstantBookable(
          instantUtc: DateTime.utc(2026, 8, 25, 11),
          items: [item(instantUtc: DateTime.utc(2026, 8, 25, 10, 30))],
          now: now,
        ),
        isTrue,
      );
    });

    test('the past is never bookable', () {
      expect(
        isInstantBookable(
          instantUtc: now.subtract(const Duration(minutes: 1)),
          items: const [],
          now: now,
        ),
        isFalse,
      );
    });
  });

  // The planner-access hint rule (`desiredAccess`) moved to planner-side and is
  // covered by test/planner_access_reconciler_test.dart.

  group('releasableSlotLocks — remove the legacy blocker', () {
    // A fixed clock: everything before noon is past, everything after is future.
    final now = DateTime.utc(2026, 8, 25, 12, 0);
    final past9 = DateTime.utc(2026, 8, 25, 9, 30);
    final past10 = DateTime.utc(2026, 8, 25, 10, 30);
    final past11 = DateTime.utc(2026, 8, 25, 11, 30);
    final future13 = DateTime.utc(2026, 8, 25, 13, 30);
    final future14 = DateTime.utc(2026, 8, 25, 14, 30);

    test('live future items release their obsolete locks too', () {
      expect(
        releasableSlotLocks([
          item(
            id: 'a',
            instantUtc: future13,
            status: ScheduleItemStatus.approved,
          ),
          item(
            id: 'b',
            instantUtc: future14,
            status: ScheduleItemStatus.pending,
          ),
        ], now),
        {
          slotIndexFor(future13): {'a'},
          slotIndexFor(future14): {'b'},
        },
      );
    });

    test('a fired-but-past approved item with NO outcome RELEASES — the '
        'alarm-dismiss bug', () {
      // Dismiss silences the alarm without marking Done, so the item stays
      // approved / no outcome, now in the past. Status-only keying stranded this
      // lock forever; the time dimension frees it.
      expect(
        releasableSlotLocks([
          item(
            id: 'a',
            instantUtc: past10,
            status: ScheduleItemStatus.approved,
          ),
        ], now),
        {
          slotIndexFor(past10): {'a'},
        },
      );
    });

    test('a slot in progress counts as past and releases', () {
      // now = 12:00; the 12:00–12:30 slot has begun (start not AFTER now), so it
      // is unbookable and its lock is cruft — same rule as `isPast`.
      final inProgress = DateTime.utc(2026, 8, 25, 12, 10);
      expect(
        releasableSlotLocks([
          item(
            id: 'a',
            instantUtc: inProgress,
            status: ScheduleItemStatus.approved,
          ),
        ], now).keys,
        {slotIndexFor(inProgress)},
      );
    });

    test('EVERY ended state on a past slot releases', () {
      // done, skipped, rejected, withdrawn, and fired-approved-untouched.
      final released = releasableSlotLocks([
        item(
          id: 'done',
          instantUtc: DateTime.utc(2026, 8, 25, 10, 0),
          outcome: const ScheduleOutcome(result: OutcomeResult.done),
        ),
        item(
          id: 'skip',
          instantUtc: past10,
          outcome: const ScheduleOutcome(result: OutcomeResult.skipped),
        ),
        item(
          id: 'rej',
          instantUtc: DateTime.utc(2026, 8, 25, 11, 0),
          status: ScheduleItemStatus.rejected,
        ),
        item(
          id: 'wd',
          instantUtc: past11,
          status: ScheduleItemStatus.withdrawn,
        ),
        item(
          id: 'fired',
          instantUtc: past9,
          status: ScheduleItemStatus.approved,
        ), // fired, no outcome
      ], now);
      expect(released.keys, {
        slotIndexFor(DateTime.utc(2026, 8, 25, 10, 0)),
        slotIndexFor(past10),
        slotIndexFor(DateTime.utc(2026, 8, 25, 11, 0)),
        slotIndexFor(past11),
        slotIndexFor(past9),
      });
    });

    test('all item ids in one future slot are cleanup candidates', () {
      expect(
        releasableSlotLocks([
          item(
            id: 'dead',
            instantUtc: future13,
            status: ScheduleItemStatus.rejected,
          ),
          item(
            id: 'live',
            instantUtc: future13.add(const Duration(minutes: 15)),
            status: ScheduleItemStatus.approved,
          ),
        ], now),
        {
          slotIndexFor(future13): {'dead', 'live'},
        },
      );
    });

    test(
      'two ended items in one PAST slot both name it as candidate owners',
      () {
        final s = DateTime.utc(2026, 8, 25, 10, 0);
        final released = releasableSlotLocks([
          item(id: 'd1', instantUtc: s, status: ScheduleItemStatus.rejected),
          item(
            id: 'd2',
            instantUtc: s.add(const Duration(minutes: 15)),
            outcome: const ScheduleOutcome(result: OutcomeResult.skipped),
          ),
        ], now);
        expect(released, {
          slotIndexFor(s): {'d1', 'd2'},
        });
      },
    );
  });
}
