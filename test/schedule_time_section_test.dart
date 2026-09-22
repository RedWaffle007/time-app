import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/outcomes/application/schedule_time_section.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  test(
    'classifies against today in the item timezone, not the device zone',
    () {
      // 18:45Z is already Sep 24 in Kolkata. This item still displays Sep 23 in
      // that same zone, so it is past even on a device whose date is Sep 23.
      final now = DateTime.utc(2026, 9, 23, 18, 45);
      final oldKolkataItem = _item(
        instant: DateTime.utc(2026, 9, 23, 17),
        timezone: 'Asia/Kolkata',
      );

      expect(
        scheduleTimeSection(oldKolkataItem, now),
        ScheduleTimeSection.past,
      );
    },
  );

  test(
    'the same local day remains today before and after its scheduled time',
    () {
      final now = DateTime.utc(2026, 9, 23, 12);

      expect(
        scheduleTimeSection(
          _item(instant: DateTime.utc(2026, 9, 23, 4), timezone: 'Etc/UTC'),
          now,
        ),
        ScheduleTimeSection.today,
      );
      expect(
        scheduleTimeSection(
          _item(instant: DateTime.utc(2026, 9, 23, 20), timezone: 'Etc/UTC'),
          now,
        ),
        ScheduleTimeSection.today,
      );
    },
  );

  test('moves from today to past exactly at the item timezone midnight', () {
    final item = _item(
      instant: DateTime.utc(2026, 9, 23, 12),
      timezone: 'Asia/Kolkata',
    );

    expect(
      scheduleTimeSection(item, DateTime.utc(2026, 9, 23, 18, 29)),
      ScheduleTimeSection.today,
    );
    expect(
      scheduleTimeSection(item, DateTime.utc(2026, 9, 23, 18, 30)),
      ScheduleTimeSection.past,
    );
  });

  test('future is also determined in the item timezone', () {
    final item = _item(
      instant: DateTime.utc(2026, 9, 24, 20),
      timezone: 'Pacific/Honolulu',
    );

    expect(
      scheduleTimeSection(item, DateTime.utc(2026, 9, 23, 18, 45)),
      ScheduleTimeSection.future,
    );
  });
}

ScheduleItem _item({required DateTime instant, required String timezone}) =>
    ScheduleItem(
      id: 'item',
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: '',
      title: 'Item',
      localWallTime: '',
      timezone: timezone,
      scheduledInstantUtc: instant,
      status: ScheduleItemStatus.approved,
    );
