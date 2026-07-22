import 'package:timezone/timezone.dart' as tz;

/// Timezone helpers. The database is loaded once in main() via
/// initializeTimeZones(), so getLocation() works anywhere after startup.

/// What happened when a wall-clock time was interpreted in a zone.
enum DstAnomaly {
  /// The wall time exists exactly once — the normal case.
  none,

  /// The wall time never occurs: clocks spring forward across it (e.g. 02:30 on
  /// a "spring forward" night). We push it forward past the gap (java.time's
  /// rule) so the item still fires on the intended night.
  skipped,

  /// The wall time occurs twice: clocks fall back across it (e.g. 01:30 on a
  /// "fall back" night). We pick the FIRST occurrence.
  ambiguous,
}

/// The resolved instant plus whether the wall time was a DST gap/overlap.
class WallTimeResolution {
  const WallTimeResolution(this.utc, this.anomaly);
  final DateTime utc;
  final DstAnomaly anomaly;
}

/// Resolve a wall-clock time (year/month/day/hour/minute as the planner typed
/// it) interpreted in [ianaZone] into an absolute UTC instant, detecting the
/// two DST edge cases the naive `TZDateTime` constructor silently papers over:
///
///   - **skipped** (spring-forward gap): the local time never happens.
///   - **ambiguous** (fall-back overlap): the local time happens twice.
///
/// Method: label the wall fields as if UTC, then shift by the two stable
/// offsets bracketing the moment (±24h — a DST shift is at most a couple of
/// hours and never happens twice within a day). A candidate instant is *real*
/// only if the zone's actual offset there equals the offset used to compute it.
/// Zero real candidates ⇒ gap; two distinct real candidates ⇒ overlap.
WallTimeResolution resolveWall(DateTime wall, String ianaZone) {
  final loc = tz.getLocation(ianaZone);
  int offsetAt(int ms) => loc.timeZone(ms).offset.inMilliseconds; // east of UTC

  final wallAsUtcMs = DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
  ).millisecondsSinceEpoch;

  const dayMs = Duration(hours: 24);
  final offBefore = offsetAt(wallAsUtcMs - dayMs.inMilliseconds);
  final offAfter = offsetAt(wallAsUtcMs + dayMs.inMilliseconds);

  final tBefore = wallAsUtcMs - offBefore;
  final tAfter = wallAsUtcMs - offAfter;
  final beforeValid = offsetAt(tBefore) == offBefore;
  final afterValid = offsetAt(tAfter) == offAfter;

  DateTime utc(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  if (offBefore == offAfter) {
    return WallTimeResolution(utc(tBefore), DstAnomaly.none);
  }
  if (beforeValid && afterValid && tBefore != tAfter) {
    // Occurs twice → ambiguous. First occurrence = the earlier instant.
    final first = tBefore < tAfter ? tBefore : tAfter;
    return WallTimeResolution(utc(first), DstAnomaly.ambiguous);
  }
  if (beforeValid != afterValid) {
    // Exactly one real interpretation, even though a transition is nearby.
    return WallTimeResolution(utc(beforeValid ? tBefore : tAfter), DstAnomaly.none);
  }
  // Neither is real → the wall time falls in a spring-forward gap. Push forward
  // past it: the later candidate lands at the shifted-forward wall time.
  final pushed = tBefore > tAfter ? tBefore : tAfter;
  return WallTimeResolution(utc(pushed), DstAnomaly.skipped);
}

/// The source of truth for when an item fires. Returns the resolved UTC instant,
/// applying the defined DST rule (see [resolveWall]).
DateTime resolveWallTimeToUtc(DateTime wall, String ianaZone) =>
    resolveWall(wall, ianaZone).utc;

/// The wall-clock string we persist alongside the zone, e.g. "2026-07-20T09:00".
/// This is a stable machine format (not shown to users) — user-facing rendering
/// lives in core/format/datetime_format.dart.
String formatWallTime(DateTime wall) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${wall.year}-${two(wall.month)}-${two(wall.day)}'
      'T${two(wall.hour)}:${two(wall.minute)}';
}
