import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/outcomes/application/schedule_partition.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

void main() {
  final boundary = DateTime.utc(2026, 11, 1, 6);

  test('only an outcome moves a plan to History — never elapsed time', () {
    final before = _item(boundary.subtract(const Duration(microseconds: 1)));
    final equal = _item(boundary);
    final after = _item(boundary.add(const Duration(microseconds: 1)));
    final longPast = _item(boundary.subtract(const Duration(hours: 20)));

    // Regression (2026-09-25): an alarm dismissed with the power button left
    // an elapsed, undecided plan in History with no Done/Skip controls.
    for (final item in [before, equal, after, longPast]) {
      expect(scheduleSurfaceFor(item, boundary), ScheduleSurface.upcoming);
      expect(
        [
          isUpcomingPlan(item, boundary),
          isHistoryPlan(item, boundary),
        ].where((belongs) => belongs),
        hasLength(1),
      );
    }
  });

  test('every outcome kind is a decision that moves to History', () {
    final past = boundary.subtract(const Duration(minutes: 5));
    final outcomes = [
      const ScheduleOutcome(result: OutcomeResult.done),
      const ScheduleOutcome(result: OutcomeResult.skipped),
      const ScheduleOutcome(
        result: OutcomeResult.skipped,
        skipReason: kUserUnavailableSkipReason,
      ),
      const ScheduleOutcome(
        result: OutcomeResult.skipped,
        skipReason: 'Did not respond',
      ),
    ];
    for (final outcome in outcomes) {
      final item = _item(past, outcome: outcome);
      expect(scheduleSurfaceFor(item, boundary), ScheduleSurface.history);
      expect(isUpcomingPlan(item, boundary), isFalse);
      expect(isHistoryPlan(item, boundary), isTrue);
    }
  });

  test('an unanswered alarm (unavailable, undecided) stays in My Schedule', () {
    final item = ScheduleItem(
      id: 'item',
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: '',
      title: 'Plan',
      localWallTime: '',
      timezone: 'Etc/UTC',
      scheduledInstantUtc: boundary.subtract(const Duration(minutes: 2)),
      status: ScheduleItemStatus.approved,
      alarm: ScheduleAlarmTimeline(
        unavailableAt: boundary.subtract(const Duration(minutes: 1)),
      ),
    );

    expect(item.wasUnavailableAtAlarmTime, isTrue);
    expect(isUpcomingPlan(item, boundary), isTrue);
    expect(isHistoryPlan(item, boundary), isFalse);
  });

  test('partition is independent of timezone and DST wall-clock ambiguity', () {
    final firstFoldHour = _item(
      DateTime.utc(2026, 11, 1, 5, 30),
      timezone: 'America/New_York',
    );
    final secondFoldHour = _item(
      DateTime.utc(2026, 11, 1, 6, 30),
      timezone: 'America/New_York',
    );
    final decidedFold = _item(
      DateTime.utc(2026, 11, 1, 5, 30),
      timezone: 'America/New_York',
      outcome: const ScheduleOutcome(result: OutcomeResult.done),
    );

    expect(
      scheduleSurfaceFor(firstFoldHour, boundary),
      ScheduleSurface.upcoming,
    );
    expect(
      scheduleSurfaceFor(secondFoldHour, boundary),
      ScheduleSurface.upcoming,
    );
    expect(scheduleSurfaceFor(decidedFold, boundary), ScheduleSurface.history);
  });

  test('recorded outcome moves even a future plan into History', () {
    final completed = _item(
      boundary.add(const Duration(days: 2)),
      outcome: const ScheduleOutcome(result: OutcomeResult.done),
    );

    expect(scheduleSurfaceFor(completed, boundary), ScheduleSurface.history);
  });

  test('non-approved items appear in neither target surface', () {
    final pending = _item(
      boundary.add(const Duration(hours: 1)),
      status: ScheduleItemStatus.pending,
    );

    expect(isUpcomingPlan(pending, boundary), isFalse);
    expect(isHistoryPlan(pending, boundary), isFalse);
  });
}

ScheduleItem _item(
  DateTime instant, {
  String timezone = 'Etc/UTC',
  ScheduleItemStatus status = ScheduleItemStatus.approved,
  ScheduleOutcome? outcome,
}) => ScheduleItem(
  id: 'item',
  targetUid: 'target',
  createdByUid: 'planner',
  groupId: '',
  title: 'Plan',
  localWallTime: '',
  timezone: timezone,
  scheduledInstantUtc: instant,
  status: status,
  outcome: outcome,
);
