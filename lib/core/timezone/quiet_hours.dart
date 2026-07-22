import 'package:timezone/timezone.dart' as tz;

/// Quiet-hours + late-night warning math. PURE time logic — no alarms, no
/// notifications, no scheduling side effects. It answers a single question:
/// "if this instant were shown in the target's local time, which warnings
/// should the planner see?" Enforcement (blocking an alarm) is deferred to the
/// alarm layer; for now the app only *warns*.

/// Fixed late-night band, warned on regardless of any user configuration
/// (spec §6: "~11pm–6am local"). Minutes since local midnight.
const int lateNightStartMinutes = 23 * 60; // 23:00
const int lateNightEndMinutes = 6 * 60; //    06:00

/// Which warnings apply to a chosen time.
class ScheduleTimeWarnings {
  const ScheduleTimeWarnings({
    required this.lateNight,
    required this.quietHours,
  });

  /// The chosen time falls in the fixed 23:00–06:00 band.
  final bool lateNight;

  /// The chosen time falls in the target's own configured quiet-hours window.
  final bool quietHours;

  bool get any => lateNight || quietHours;
}

/// True if [minuteOfDay] is within the half-open window `[start, end)`, handling
/// windows that wrap past midnight (start > end), e.g. 23:00–06:00. A
/// zero-length window (start == end) matches nothing.
bool minuteInWindow(int minuteOfDay, int start, int end) {
  if (start == end) return false;
  if (start < end) return minuteOfDay >= start && minuteOfDay < end;
  return minuteOfDay >= start || minuteOfDay < end; // wraps midnight
}

/// Compute the warnings for [utcInstant] as seen in [ianaZone], given the
/// target's optional quiet-hours window (minutes since local midnight, may
/// wrap). When either bound is null the quiet-hours check is simply skipped.
ScheduleTimeWarnings warningsForInstant(
  DateTime utcInstant,
  String ianaZone, {
  int? quietStartMinutes,
  int? quietEndMinutes,
}) {
  final local = tz.TZDateTime.from(utcInstant, tz.getLocation(ianaZone));
  final minute = local.hour * 60 + local.minute;

  final quiet = (quietStartMinutes != null && quietEndMinutes != null)
      ? minuteInWindow(minute, quietStartMinutes, quietEndMinutes)
      : false;

  return ScheduleTimeWarnings(
    lateNight: minuteInWindow(minute, lateNightStartMinutes, lateNightEndMinutes),
    quietHours: quiet,
  );
}
