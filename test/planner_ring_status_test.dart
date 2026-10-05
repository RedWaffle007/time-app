import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/reminders/domain/reminder.dart';
import 'package:time_app/features/scheduling/application/planner_ring_status.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/planner_activity_screen.dart';

/// The planner sees the live ring state from the target phone's ring record
/// (ring queue, 2026-10-05), with no push per ring.
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

  ScheduleAlarmTimeline record(
    int ring,
    Duration startedAfter,
    Duration length, {
    Duration? nextAfter,
    DateTime? dismissedAt,
    DateTime? unavailableAt,
  }) => ScheduleAlarmTimeline(
    rangAt: due,
    ring: ring,
    ringAt: due.add(startedAfter),
    ringEndsAt: due.add(startedAfter + length),
    nextRingAt: nextAfter == null ? null : due.add(nextAfter),
    dismissedAt: dismissedAt,
    unavailableAt: unavailableAt,
  );

  final rang = record(
    1,
    Duration.zero,
    const Duration(minutes: 1),
    nextAfter: const Duration(minutes: 10),
  );

  test('ringing, then waiting with the forecast, from the ring record', () {
    final i = item(alarm: rang);
    expect((plannerRingStatus(i, due) as PlannerRinging).ring, 1);
    final w = plannerRingStatus(i, due.add(const Duration(minutes: 3)));
    expect((w as PlannerWaiting).ringsDone, 1);
    expect(w.nextRingAtUtc, due.add(const Duration(minutes: 10)));
    // A pushed-back repeat, recorded when it rang.
    final repeat = item(
      alarm: record(
        2,
        const Duration(minutes: 47),
        const Duration(minutes: 2),
        nextAfter: const Duration(minutes: 57),
      ),
    );
    expect(
      (plannerRingStatus(repeat, due.add(const Duration(minutes: 48)))
              as PlannerRinging)
          .ring,
      2,
    );
  });

  test('after the last ring nothing live is left to say', () {
    final last = item(
      alarm: record(3, const Duration(minutes: 20), const Duration(minutes: 2)),
    );
    expect(
      plannerRingStatus(last, due.add(const Duration(minutes: 30))),
      isNull,
    );
  });

  test('a record without a ring (an older phone) shows nothing', () {
    expect(
      plannerRingStatus(item(alarm: ScheduleAlarmTimeline(rangAt: due)), due),
      isNull,
    );
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
    await pumpLine(t, const Duration(seconds: 20));
    expect(find.text('Ringing now'), findsOneWidget);
    await pumpLine(t, const Duration(minutes: 6));
    expect(
      find.textContaining('Not answered · rings again about'),
      findsOneWidget,
    );
    await pumpLine(t, const Duration(minutes: 12));
    expect(
      find.text('Not answered after 1 of 3 · reminder pending'),
      findsOneWidget,
    );
  });

  testWidgets('a repeat reads its number', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: PlannerRingStatusLine(
            item: item(
              alarm: record(
                2,
                const Duration(minutes: 10),
                const Duration(minutes: 2),
              ),
            ),
            now: () => due.add(const Duration(minutes: 11)),
          ),
        ),
      ),
    );
    expect(find.text('Ringing · reminder 2 of 3'), findsOneWidget);
  });

  test('the ring count in words matches the native queue', () {
    expect(kPlannerRingCount, kAlarmRingCount);
  });
}
