import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/outcomes/application/schedule_partition.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

void main() {
  final boundary = DateTime.utc(2026, 11, 1, 6);

  test('due instant is the single disjoint Upcoming/History boundary', () {
    final before = _item(boundary.subtract(const Duration(microseconds: 1)));
    final equal = _item(boundary);
    final after = _item(boundary.add(const Duration(microseconds: 1)));

    expect(scheduleSurfaceFor(before, boundary), ScheduleSurface.history);
    expect(scheduleSurfaceFor(equal, boundary), ScheduleSurface.upcoming);
    expect(scheduleSurfaceFor(after, boundary), ScheduleSurface.upcoming);
    for (final item in [before, equal, after]) {
      expect(
        [
          isUpcomingPlan(item, boundary),
          isHistoryPlan(item, boundary),
        ].where((belongs) => belongs),
        hasLength(1),
      );
    }
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

    expect(
      scheduleSurfaceFor(firstFoldHour, boundary),
      ScheduleSurface.history,
    );
    expect(
      scheduleSurfaceFor(secondFoldHour, boundary),
      ScheduleSurface.upcoming,
    );
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
