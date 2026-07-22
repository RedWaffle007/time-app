import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:time_app/core/timezone/tz_resolver.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  // America/New_York 2026: spring forward Sun Mar 8 02:00→03:00;
  // fall back Sun Nov 1 02:00→01:00.
  const ny = 'America/New_York';

  // Wall times are timezone-agnostic field carriers, so they're built as
  // UTC-kind DateTimes (as the app does) — a local DateTime(...) would be
  // normalized by the HOST's zone before it reaches the resolver, which is the
  // very bug the app avoids by constructing wall times with DateTime.utc.

  // The resolved instant, rendered back in the zone, as (hour, minute).
  (int, int) localHm(DateTime utc, String zone) {
    final t = tz.TZDateTime.from(utc, tz.getLocation(zone));
    return (t.hour, t.minute);
  }

  test('normal time resolves unambiguously', () {
    final res = resolveWall(DateTime.utc(2026, 6, 15, 9, 0), ny);
    expect(res.anomaly, DstAnomaly.none);
    // 09:00 EDT (-04:00) == 13:00 UTC.
    expect(res.utc, DateTime.utc(2026, 6, 15, 13, 0));
  });

  test('spring-forward gap is detected and pushed forward', () {
    // 02:30 never happens on Mar 8, 2026.
    final res = resolveWall(DateTime.utc(2026, 3, 8, 2, 30), ny);
    expect(res.anomaly, DstAnomaly.skipped);
    // Pushed to 03:30 EDT (-04:00) == 07:30 UTC; renders as 03:30 local.
    expect(res.utc, DateTime.utc(2026, 3, 8, 7, 30));
    expect(localHm(res.utc, ny), (3, 30));
  });

  test('fall-back overlap is detected and takes the first occurrence', () {
    // 01:30 happens twice on Nov 1, 2026.
    final res = resolveWall(DateTime.utc(2026, 11, 1, 1, 30), ny);
    expect(res.anomaly, DstAnomaly.ambiguous);
    // First occurrence is still EDT (-04:00) == 05:30 UTC (not 06:30 EST).
    expect(res.utc, DateTime.utc(2026, 11, 1, 5, 30));
    expect(localHm(res.utc, ny), (1, 30));
  });

  test('round-trips: rendering the resolved instant shows the entered time', () {
    // A DST-free zone must round-trip exactly.
    final res = resolveWall(DateTime.utc(2026, 7, 20, 9, 0), 'Asia/Kolkata');
    expect(res.anomaly, DstAnomaly.none);
    expect(localHm(res.utc, 'Asia/Kolkata'), (9, 0));
  });

  test('southern-hemisphere transition (offset decreases) still resolves', () {
    // Australia/Sydney 2026: clocks fall back Sun Apr 5 03:00→02:00.
    final res = resolveWall(DateTime.utc(2026, 4, 5, 2, 30), 'Australia/Sydney');
    expect(res.anomaly, DstAnomaly.ambiguous);
  });
}
