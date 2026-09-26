import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/timezone/tz_resolver.dart';
import 'package:time_app/features/scheduling/application/schedule_clash.dart';
import 'package:time_app/features/scheduling/domain/minute_lock.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// Batch G1 → item 4: a clash is a LITERAL one — a live plan at the exact
/// minute being planned — and the schedule read never gets stuck. Since item 4
/// a clash BLOCKS the plan (server-side minute locks; see
/// firestore-tests/minute_locks.test.mjs).
void main() {
  setUpAll(tzdata.initializeTimeZones);

  ScheduleItem item({
    String id = 'i',
    required DateTime instant,
    ScheduleItemStatus status = ScheduleItemStatus.approved,
    ScheduleOutcome? outcome,
  }) {
    return ScheduleItem(
      id: id,
      targetUid: 'TARGET',
      createdByUid: 'PLANNER',
      groupId: '',
      title: 'private title',
      note: 'private note',
      localWallTime: '',
      timezone: 'America/Vancouver',
      scheduledInstantUtc: instant,
      status: status,
      outcome: outcome,
    );
  }

  group('clashesAt', () {
    final at = DateTime.utc(2026, 10, 5, 1); // 18:00 Vancouver (PDT)

    test('an empty schedule never clashes', () {
      expect(clashesAt(const [], at), isFalse);
    });

    test('a live plan at the same minute clashes (approved and pending)', () {
      expect(clashesAt([item(instant: at)], at), isTrue);
      expect(
        clashesAt([item(instant: at, status: ScheduleItemStatus.pending)], at),
        isTrue,
      );
    });

    test('seconds inside the same minute still clash', () {
      expect(
        clashesAt([item(instant: at.add(const Duration(seconds: 30)))], at),
        isTrue,
      );
    });

    test('one minute either side, or elsewhere that day, does not', () {
      expect(
        clashesAt([
          item(id: 'a', instant: at.add(const Duration(minutes: 1))),
          item(id: 'b', instant: at.subtract(const Duration(minutes: 1))),
          item(id: 'c', instant: at.subtract(const Duration(hours: 6))),
        ], at),
        isFalse,
      );
    });

    test('settled, rejected or cancelled plans never count', () {
      expect(
        clashesAt([
          item(
            id: 'done',
            instant: at,
            outcome: const ScheduleOutcome(result: OutcomeResult.done),
          ),
          item(
            id: 'skipped',
            instant: at,
            outcome: const ScheduleOutcome(result: OutcomeResult.skipped),
          ),
          item(
            id: 'rejected',
            instant: at,
            status: ScheduleItemStatus.rejected,
          ),
          item(
            id: 'withdrawn',
            instant: at,
            status: ScheduleItemStatus.withdrawn,
          ),
          item(
            id: 'cancelled',
            instant: at,
            status: ScheduleItemStatus.cancelled,
          ),
        ], at),
        isFalse,
      );
    });

    test('an earlier unanswered alarm that day does not count', () {
      expect(
        clashesAt([item(instant: at.subtract(const Duration(hours: 3)))], at),
        isFalse,
      );
    });

    test('compares in the TARGET zone: same wall time elsewhere is not a '
        'clash', () {
      // 18:00 in Kolkata is a different absolute minute from 18:00 Vancouver.
      final kolkata18 = resolveWallTimeToUtc(
        DateTime.utc(2026, 10, 4, 18),
        'Asia/Kolkata',
      );
      final vancouver18 = resolveWallTimeToUtc(
        DateTime.utc(2026, 10, 4, 18),
        'America/Vancouver',
      );
      expect(vancouver18, at);
      expect(clashesAt([item(instant: kolkata18)], vancouver18), isFalse);
      expect(clashesAt([item(instant: vancouver18)], vancouver18), isTrue);
    });

    test('DST fall-back: the two 01:30s are different minutes', () {
      // Vancouver 2026-11-01: 01:30 PDT = 08:30Z, then 01:30 PST = 09:30Z.
      final first = DateTime.utc(2026, 11, 1, 8, 30);
      final second = DateTime.utc(2026, 11, 1, 9, 30);
      expect(clashesAt([item(instant: first)], second), isFalse);
      expect(clashesAt([item(instant: first)], first), isTrue);
    });
  });

  group('ScheduleClashChecker', () {
    final at = DateTime.utc(2026, 10, 5, 1);
    const noWait = [Duration.zero, Duration.zero, Duration.zero];

    test('clear and clash on a readable schedule', () async {
      final clear = ScheduleClashChecker(fetch: (_) async => []);
      final busy = ScheduleClashChecker(
        fetch: (_) async => [item(instant: at)],
      );
      expect(
        await clear.check(targetUid: 'TARGET', instantUtc: at),
        ClashResult.clear,
      );
      expect(
        await busy.check(targetUid: 'TARGET', instantUtc: at),
        ClashResult.clash,
      );
    });

    test('a refusal followed by success is retried, not reported', () async {
      var calls = 0;
      final checker = ScheduleClashChecker(
        fetch: (_) async {
          calls++;
          if (calls < 3) throw Exception('permission-denied');
          return [item(instant: at)];
        },
        retryDelays: noWait,
      );
      expect(
        await checker.check(targetUid: 'TARGET', instantUtc: at),
        ClashResult.clash,
      );
      expect(calls, 3);
    });

    test(
      'a permanent refusal gives up after 1 + 3 attempts as unknown',
      () async {
        var calls = 0;
        final checker = ScheduleClashChecker(
          fetch: (_) async {
            calls++;
            throw Exception('permission-denied');
          },
          retryDelays: noWait,
        );
        expect(
          await checker.check(targetUid: 'TARGET', instantUtc: at),
          ClashResult.unknown,
        );
        expect(calls, 4);
      },
    );

    test('a hung read times out and is retried', () async {
      var calls = 0;
      final checker = ScheduleClashChecker(
        fetch: (_) {
          calls++;
          if (calls == 1) return Future.delayed(const Duration(hours: 1));
          return Future.value(const <ScheduleItem>[]);
        },
        retryDelays: noWait,
        attemptTimeout: const Duration(milliseconds: 10),
      );
      expect(
        await checker.check(targetUid: 'TARGET', instantUtc: at),
        ClashResult.clear,
      );
      expect(calls, 2);
    });
  });

  test('the day-scoped rule, the dying listener and the warning dialog are '
      'gone', () {
    for (final path in [
      'lib/features/scheduling/application/conflict_disclosure.dart',
      'lib/features/scheduling/application/target_schedule_providers.dart',
      'lib/features/scheduling/presentation/conflict_warning_dialog.dart',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
    for (final path in [
      'lib/features/scheduling/presentation/schedule_builder_screen.dart',
      'lib/features/scheduling/presentation/group_plan_sheet.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('targetScheduleProvider')));
      expect(source, isNot(contains('Schedule heads-up')));
      expect(source, isNot(contains('showTargetScheduleModal')));
    }
  });

  test('the minute-lock key matches the rules and the Worker', () {
    // Seconds are dropped; whole minutes since the epoch are kept.
    final at = DateTime.utc(2030, 10, 5, 1);
    expect(minuteLockId(at), '${at.millisecondsSinceEpoch ~/ 60000}');
    expect(minuteLockId(at.add(const Duration(seconds: 59))), minuteLockId(at));
    expect(
      minuteLockId(at.add(const Duration(minutes: 1))),
      isNot(minuteLockId(at)),
    );
    // Same instant expressed in another zone: same key.
    expect(minuteLockId(at.toLocal()), minuteLockId(at));
    final rules = File('firestore.rules').readAsStringSync();
    expect(rules, contains('string(int(math.floor(ts.toMillis() / 60000)))'));
  });
}
