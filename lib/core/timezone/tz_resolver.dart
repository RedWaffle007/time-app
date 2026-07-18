import 'package:timezone/timezone.dart' as tz;

/// Timezone helpers. The database is loaded once in main() via
/// initializeTimeZones(), so getLocation() works anywhere after startup.

/// Resolve a wall-clock time (year/month/day/hour/minute as the planner typed
/// it) interpreted in [ianaZone] into an absolute UTC instant. DST-correct for
/// that date. This is the source of truth for when an item fires.
DateTime resolveWallTimeToUtc(DateTime wall, String ianaZone) {
  final location = tz.getLocation(ianaZone);
  final local = tz.TZDateTime(
    location,
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
  );
  return local.toUtc();
}

/// The wall-clock string we persist alongside the zone, e.g. "2026-07-20T09:00".
String formatWallTime(DateTime wall) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${wall.year}-${two(wall.month)}-${two(wall.day)}'
      'T${two(wall.hour)}:${two(wall.minute)}';
}

/// Human-friendly rendering of a UTC instant as seen in [ianaZone], e.g.
/// "Mon 20 Jul 2026, 09:00". Used to show the target's local time.
String formatInZone(DateTime utcInstant, String ianaZone) {
  final location = tz.getLocation(ianaZone);
  final t = tz.TZDateTime.from(utcInstant, location);
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${days[t.weekday - 1]} ${t.day} ${months[t.month - 1]} ${t.year}, '
      '${two(t.hour)}:${two(t.minute)}';
}
