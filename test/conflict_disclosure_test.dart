import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/features/scheduling/application/conflict_disclosure.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/conflict_warning_dialog.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  ScheduleItem item({
    required String id,
    required DateTime instant,
    ScheduleItemStatus status = ScheduleItemStatus.pending,
    ScheduleOutcome? outcome,
    String title = 'private title',
    String? note = 'private note',
  }) {
    return ScheduleItem(
      id: id,
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: '',
      title: title,
      note: note,
      localWallTime: '',
      timezone: 'America/Chicago',
      scheduledInstantUtc: instant,
      status: status,
      outcome: outcome,
    );
  }

  group('day-scoped conflict projection', () {
    test('includes only live pending/approved outcome-less items', () {
      final instant = DateTime.utc(2026, 8, 25, 15);
      final result = conflictInstantsForLocalDay(
        localDay: DateTime(2026, 8, 25),
        timezone: 'UTC',
        items: [
          item(id: 'pending', instant: instant),
          item(
            id: 'approved',
            instant: instant.add(const Duration(hours: 1)),
            status: ScheduleItemStatus.approved,
          ),
          item(
            id: 'rejected',
            instant: instant.add(const Duration(hours: 2)),
            status: ScheduleItemStatus.rejected,
          ),
          item(
            id: 'done',
            instant: instant.add(const Duration(hours: 3)),
            status: ScheduleItemStatus.approved,
            outcome: const ScheduleOutcome(result: OutcomeResult.done),
          ),
        ],
      );

      expect(result, [instant, instant.add(const Duration(hours: 1))]);
    });

    test('uses the target local day across a spring-forward boundary', () {
      // Chicago 2026-03-08 is 06:00Z → 05:00Z next day (23 hours).
      final result = conflictInstantsForLocalDay(
        localDay: DateTime(2026, 3, 8),
        timezone: 'America/Chicago',
        items: [
          item(id: 'before', instant: DateTime.utc(2026, 3, 8, 5, 59)),
          item(id: 'start', instant: DateTime.utc(2026, 3, 8, 6)),
          item(id: 'end-minus', instant: DateTime.utc(2026, 3, 9, 4, 59)),
          item(id: 'end', instant: DateTime.utc(2026, 3, 9, 5)),
        ],
      );

      expect(result, [
        DateTime.utc(2026, 3, 8, 6),
        DateTime.utc(2026, 3, 9, 4, 59),
      ]);
    });

    test('sorts and deduplicates instants without exposing item count', () {
      final early = DateTime.utc(2026, 8, 25, 8);
      final late = DateTime.utc(2026, 8, 25, 9);
      final result = conflictInstantsForLocalDay(
        localDay: DateTime(2026, 8, 25),
        timezone: 'UTC',
        items: [
          item(id: 'late', instant: late),
          item(id: 'early-a', instant: early),
          item(id: 'early-b', instant: early),
        ],
      );

      expect(result, [early, late]);
    });
  });

  group('fingerprints', () {
    final day = DateTime(2026, 8, 25);
    final a = ConflictDisclosureGroup(
      uid: 'a',
      name: 'Alice',
      timezone: 'Asia/Kolkata',
      instantsUtc: [DateTime.utc(2026, 8, 25, 4)],
    );
    final b = ConflictDisclosureGroup(
      uid: 'b',
      name: 'Bob',
      timezone: 'America/Chicago',
      instantsUtc: [DateTime.utc(2026, 8, 25, 14)],
    );

    test('is stable across group order and display-name changes', () {
      final first = conflictDisclosureFingerprint(
        localDay: day,
        groups: [a, b],
      );
      final second = conflictDisclosureFingerprint(
        localDay: day,
        groups: [
          b,
          ConflictDisclosureGroup(
            uid: a.uid,
            name: 'Renamed',
            timezone: a.timezone,
            instantsUtc: a.instantsUtc,
          ),
        ],
      );
      expect(second, first);
    });

    test('changes for day, feed, zone, or read-error changes', () {
      final base = conflictDisclosureFingerprint(localDay: day, groups: [a]);
      expect(
        conflictDisclosureFingerprint(
          localDay: day.add(const Duration(days: 1)),
          groups: [a],
        ),
        isNot(base),
      );
      expect(
        conflictDisclosureFingerprint(localDay: day, groups: [a, b]),
        isNot(base),
      );
      expect(
        conflictDisclosureFingerprint(
          localDay: day,
          groups: [a],
          errorUids: const ['c:permission-denied'],
        ),
        isNot(base),
      );
    });
  });

  testWidgets('warning reveals only grouped times and does not block saving', (
    tester,
  ) async {
    var saves = 0;
    final group = ConflictDisclosureGroup(
      uid: 'target',
      name: 'Alex',
      timezone: 'Asia/Kolkata',
      instantsUtc: [DateTime.utc(2026, 8, 25, 4)],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                FilledButton(
                  onPressed: () =>
                      showConflictWarningDialog(context, groups: [group]),
                  child: const Text('Check'),
                ),
                FilledButton(
                  onPressed: () => saves++,
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    expect(find.text('Alex'), findsOneWidget);
    expect(find.textContaining('Asia/Kolkata'), findsWidgets);
    expect(find.textContaining('private title'), findsNothing);
    expect(find.textContaining('private note'), findsNothing);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    expect(saves, 1);
  });

  testWidgets('read failures are explicit and remain informational', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showConflictWarningDialog(
                context,
                groups: const [],
                readErrors: const {'target': 'Alex'},
              ),
              child: const Text('Check'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();

    expect(find.text('Could not check:'), findsOneWidget);
    expect(find.text('Alex'), findsOneWidget);
    expect(find.textContaining('You can still save'), findsOneWidget);
  });

  test('the full-schedule preview and its builder entry point are removed', () {
    final builder = File(
      'lib/features/scheduling/presentation/schedule_builder_screen.dart',
    ).readAsStringSync();
    expect(builder, isNot(contains('showTargetScheduleModal')));
    expect(builder, isNot(contains('schedule & pick a slot')));
    expect(
      File(
        'lib/features/scheduling/presentation/target_schedule_modal.dart',
      ).existsSync(),
      isFalse,
    );
  });
}
