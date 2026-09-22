import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/scheduling/application/schedule_item_order.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  test('same-date schedule cards sort from latest to oldest', () {
    final items = [
      _item('morning', DateTime.utc(2026, 9, 23, 8)),
      _item('evening', DateTime.utc(2026, 9, 23, 18)),
      _item('afternoon', DateTime.utc(2026, 9, 23, 13)),
    ]..sort(compareScheduleItemsLatestFirst);

    expect(items.map((item) => item.id), ['evening', 'afternoon', 'morning']);
  });

  test('pending dates stay ascending while each date is latest-first', () {
    final items = [
      _item('day-two-early', DateTime.utc(2026, 9, 24, 8)),
      _item('day-one-early', DateTime.utc(2026, 9, 23, 8)),
      _item('day-one-late', DateTime.utc(2026, 9, 23, 18)),
    ]..sort(compareScheduleItemsDayAscendingLatestFirst);

    expect(items.map((item) => item.id), [
      'day-one-late',
      'day-one-early',
      'day-two-early',
    ]);
  });

  test('equal-time ordering is deterministic', () {
    final instant = DateTime.utc(2026, 9, 23, 12);
    final items = [
      _item('z', instant, title: 'Same'),
      _item('b', instant, title: 'Beta'),
      _item('a', instant, title: 'Same'),
    ]..sort(compareScheduleItemsLatestFirst);

    expect(items.map((item) => item.id), ['b', 'a', 'z']);
  });
}

ScheduleItem _item(String id, DateTime instant, {String? title}) =>
    ScheduleItem(
      id: id,
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: '',
      title: title ?? id,
      localWallTime: '',
      timezone: 'Etc/UTC',
      scheduledInstantUtc: instant,
      status: ScheduleItemStatus.approved,
    );
