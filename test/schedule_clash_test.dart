import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/timezone/tz_resolver.dart';
import 'package:time_app/features/scheduling/application/schedule_clash.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/conflict_warning_dialog.dart';

/// Batch G1: the clash warning fires only on a LITERAL clash — a live plan at
/// the exact minute being planned — and the schedule read never gets stuck.
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

  group('dialog', () {
    Future<void> open(
      WidgetTester tester,
      List<String> names, {
      VoidCallback? onSave,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  FilledButton(
                    onPressed: () => showClashWarningDialog(
                      context,
                      names: names,
                      timeLabel: '6:00 PM',
                    ),
                    child: const Text('Check'),
                  ),
                  FilledButton(onPressed: onSave, child: const Text('Save')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
    }

    testWidgets('one person: names them and the time, and does not block', (
      tester,
    ) async {
      var saves = 0;
      await open(tester, ['Test Target'], onSave: () => saves++);
      expect(
        find.text(
          'Test Target already has a plan at 6:00 PM. You can still send.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      expect(saves, 1);
    });

    testWidgets('a group: one popup, names sorted', (tester) async {
      await open(tester, ['Member B', 'Member A']);
      expect(
        find.text(
          'Already busy at this time (6:00 PM): Member A, Member B. '
          'You can still send.',
        ),
        findsOneWidget,
      );
    });
  });

  test('the day-scoped rule and the dying listener are gone', () {
    expect(
      File(
        'lib/features/scheduling/application/conflict_disclosure.dart',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        'lib/features/scheduling/application/target_schedule_providers.dart',
      ).existsSync(),
      isFalse,
    );
    for (final path in [
      'lib/features/scheduling/presentation/schedule_builder_screen.dart',
      'lib/features/scheduling/presentation/group_plan_sheet.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('targetScheduleProvider')));
      expect(source, isNot(contains('Could not check')));
      expect(source, isNot(contains('showTargetScheduleModal')));
    }
  });
}
