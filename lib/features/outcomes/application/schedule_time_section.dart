import 'package:timezone/timezone.dart' as tz;

import '../../calendar/application/calendar_grouping.dart';
import '../../scheduling/domain/schedule_item.dart';

/// The time section an item belongs to in My Schedule.
///
/// "Today" is evaluated in the item's own stored timezone, matching the date
/// and time printed on its card. Comparing that date with the phone's local
/// date can label an already-old item as future when the two zones straddle
/// midnight.
enum ScheduleTimeSection { today, future, past }

ScheduleTimeSection scheduleTimeSection(ScheduleItem item, DateTime now) {
  final itemDay = calendarDayFor(item);
  final nowDay = _dayInZone(now, item.timezone);
  final comparison = itemDay.compareTo(nowDay);
  if (comparison < 0) return ScheduleTimeSection.past;
  if (comparison > 0) return ScheduleTimeSection.future;
  return ScheduleTimeSection.today;
}

/// A UTC-midnight field carrier, like [calendarDayFor], for [instant] rendered
/// in [timezone]. Unknown legacy zones use the device zone, matching
/// `itemWallTime`'s existing fallback rather than making the screen fail.
DateTime _dayInZone(DateTime instant, String timezone) {
  DateTime wall;
  try {
    wall = tz.TZDateTime.from(instant.toUtc(), tz.getLocation(timezone));
  } catch (_) {
    wall = instant.toLocal();
  }
  return DateTime.utc(wall.year, wall.month, wall.day);
}
