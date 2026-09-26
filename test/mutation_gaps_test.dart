import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/timezone/quiet_hours.dart';
import 'package:time_app/features/scheduling/application/item_lapse_policy.dart';
import 'package:time_app/features/scheduling/application/slot_availability.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

ScheduleItem _item({
  required String id,
  required DateTime at,
  String zone = 'UTC',
}) => ScheduleItem(
  id: id,
  targetUid: 'target',
  createdByUid: 'planner',
  groupId: 'g',
  title: id,
  localWallTime: '',
  timezone: zone,
  scheduledInstantUtc: at,
  status: ScheduleItemStatus.approved,
);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('a zero-length quiet window matches nothing', () {
    for (final endpoint in [0, 1, 360, 720, 1439]) {
      for (final minute in [0, 1, 359, 720, 1439]) {
        expect(minuteInWindow(minute, endpoint, endpoint), isFalse);
      }
    }
  });

  test('nextFreeSlot includes the exact from slot', () {
    const from = 100;
    final slots = [
      const TargetSlot(index: from - 1, occupants: [], isPast: false),
      const TargetSlot(index: from, occupants: [], isPast: false),
      const TargetSlot(index: from + 1, occupants: [], isPast: false),
    ];
    expect(nextFreeSlot(slots, from: from)?.index, from);
  });

  test('an instant equal to now is not bookable', () {
    final now = DateTime.utc(2026, 8, 25, 12);
    expect(
      isInstantBookable(instantUtc: now, items: const [], now: now),
      isFalse,
    );
  });

  test('unknown zones use the next UTC midnight, not two days later', () {
    final item = _item(
      id: 'bad-zone',
      at: DateTime.utc(2026, 8, 25, 23, 30),
      zone: 'Not/AZone',
    );
    expect(endOfScheduledLocalDayUtc(item), DateTime.utc(2026, 8, 26));
    // 23:30 is within two hours of that midnight, so the response deadline is
    // the two-hour minimum (2026-09-26), still one day — never two.
    expect(responseDeadlineUtc(item), DateTime.utc(2026, 8, 26, 1, 30));
    expect(hasLapsed(item, DateTime.utc(2026, 8, 26, 1, 29)), isFalse);
    expect(hasLapsed(item, DateTime.utc(2026, 8, 26, 1, 30)), isTrue);
  });
}
