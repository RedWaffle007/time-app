import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/timezone/tz_resolver.dart';

/// Batch G2: `wallNowIn` — what a clock in another zone reads right now.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  final now = DateTime.utc(2026, 9, 27, 4, 30);

  test('Vancouver is still Saturday evening', () {
    expect(
      wallNowIn('America/Vancouver', nowUtc: now),
      DateTime(2026, 9, 26, 21, 30),
    );
  });

  test('Kolkata is Sunday morning', () {
    expect(wallNowIn('Asia/Kolkata', nowUtc: now), DateTime(2026, 9, 27, 10));
  });

  test('either side of the date line differs by a calendar day', () {
    expect(
      wallNowIn('Pacific/Kiritimati', nowUtc: now),
      DateTime(2026, 9, 27, 18, 30),
    );
    expect(
      wallNowIn('Pacific/Pago_Pago', nowUtc: now),
      DateTime(2026, 9, 26, 17, 30),
    );
  });

  test('DST fall-back: both 01:30s read 01:30', () {
    expect(
      wallNowIn('America/Vancouver', nowUtc: DateTime.utc(2026, 11, 1, 8, 30)),
      DateTime(2026, 11, 1, 1, 30),
    );
    expect(
      wallNowIn('America/Vancouver', nowUtc: DateTime.utc(2026, 11, 1, 9, 30)),
      DateTime(2026, 11, 1, 1, 30),
    );
  });

  test('DST spring-forward: 02:00 PST is 03:00 PDT', () {
    expect(
      wallNowIn('America/Vancouver', nowUtc: DateTime.utc(2026, 3, 8, 9, 59)),
      DateTime(2026, 3, 8, 1, 59),
    );
    expect(
      wallNowIn('America/Vancouver', nowUtc: DateTime.utc(2026, 3, 8, 10)),
      DateTime(2026, 3, 8, 3),
    );
  });

  test('truncates to the minute', () {
    expect(
      wallNowIn('Etc/UTC', nowUtc: DateTime.utc(2026, 9, 27, 4, 30, 59, 999)),
      DateTime(2026, 9, 27, 4, 30),
    );
  });

  test('an unknown zone falls back to the device time instead of throwing', () {
    final local = now.toLocal();
    expect(
      wallNowIn('Not/AZone', nowUtc: now),
      DateTime(local.year, local.month, local.day, local.hour, local.minute),
    );
  });

  test('defaults to the injectable clock', () {
    withClock(Clock.fixed(now), () {
      expect(wallNowIn('Asia/Kolkata'), DateTime(2026, 9, 27, 10));
    });
  });
}
