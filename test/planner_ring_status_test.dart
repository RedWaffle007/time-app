import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/reminders/application/ring_cycle.dart';
import 'package:time_app/features/scheduling/application/planner_ring_status.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/planner_activity_screen.dart';

/// 2026-10-04: the planner sees the live ring state, with no push per ring.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  final due = DateTime.utc(2030, 1, 1, 9);

  ScheduleItem item({
    ScheduleAlarmTimeline? alarm,
    ScheduleOutcome? outcome,
    ScheduleItemStatus status = ScheduleItemStatus.approved,
  }) => ScheduleItem(
    id: 'a',
    targetUid: 'friend',
    createdByUid: 'me',
    groupId: '',
    title: 'Run',
    localWallTime: '',
    timezone: 'Etc/UTC',
    scheduledInstantUtc: due,
    status: status,
    outcome: outcome,
    alarm: alarm,
  );

  final rang = ScheduleAlarmTimeline(rangAt: due);

  test('ringing, quiet, then nothing once the cycle is over', () {
    final i = item(alarm: rang);
    expect(plannerRingStatus(i, due), isA<Ringing>());
    final r2 = plannerRingStatus(i, due.add(const Duration(minutes: 12)));
    expect((r2 as Ringing).ring, 2);
    final q = plannerRingStatus(i, due.add(const Duration(minutes: 16)));
    expect((q as Quiet).nextRingAtUtc, due.add(const Duration(minutes: 20)));
    expect(plannerRingStatus(i, due.add(kRingCycleTotal)), isNull);
  });

  test('nothing until the target phone reports it rang', () {
    expect(plannerRingStatus(item(), due), isNull);
  });

  test('nothing once answered, dismissed or unavailable', () {
    expect(
      plannerRingStatus(
        item(
          alarm: ScheduleAlarmTimeline(rangAt: due, dismissedAt: due),
        ),
        due.add(const Duration(minutes: 1)),
      ),
      isNull,
    );
    expect(
      plannerRingStatus(
        item(
          alarm: ScheduleAlarmTimeline(rangAt: due, unavailableAt: due),
        ),
        due.add(const Duration(minutes: 1)),
      ),
      isNull,
    );
    expect(
      plannerRingStatus(
        item(
          alarm: rang,
          outcome: ScheduleOutcome(
            result: OutcomeResult.done,
            completedAt: due,
          ),
        ),
        due.add(const Duration(minutes: 1)),
      ),
      isNull,
    );
  });

  Future<void> pumpLine(WidgetTester t, Duration after) => t.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: PlannerRingStatusLine(
          item: item(alarm: rang),
          now: () => due.add(after),
        ),
      ),
    ),
  );

  testWidgets('the card line reads which ring, or when it rings again', (
    t,
  ) async {
    await pumpLine(t, const Duration(minutes: 11));
    expect(find.text('Ringing · 2 of 3'), findsOneWidget);
    await pumpLine(t, const Duration(minutes: 6));
    expect(find.textContaining('Quiet · rings again'), findsOneWidget);
    await pumpLine(t, const Duration(minutes: 30));
    expect(find.byKey(const ValueKey('planner-ring-status')), findsNothing);
  });
}
