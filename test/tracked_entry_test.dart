import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/time_tracking/domain/tracked_entry.dart';

void main() {
  group('apportionAcrossDays', () {
    test('single day gets the whole amount', () {
      final shares = apportionAcrossDays(45, ['2026-08-25']);
      expect(shares, hasLength(1));
      expect(shares.single.minutes, 45);
      expect(shares.single.logDate, '2026-08-25');
    });

    test('splits evenly and re-sums to the exact total', () {
      final shares = apportionAcrossDays(100, ['d1', 'd2', 'd3']);
      expect(shares.map((s) => s.minutes).toList(), [34, 33, 33]);
      expect(shares.fold<int>(0, (a, s) => a + s.minutes), 100);
    });

    test('every share obeys the one-day cap', () {
      final shares = apportionAcrossDays(2880, ['d1', 'd2']); // exactly 2 days
      expect(shares.map((s) => s.minutes).toList(), [1440, 1440]);
    });

    test('throws when the total cannot fit in the chosen days', () {
      expect(
        () => apportionAcrossDays(1441, ['only-one-day']),
        throwsA(isA<ApportionmentImpossible>()),
      );
    });

    test('throws on fewer minutes than days (would force a 0 share)', () {
      expect(
        () => apportionAcrossDays(2, ['d1', 'd2', 'd3']),
        throwsA(isA<ApportionmentImpossible>()),
      );
    });

    test('throws on no days', () {
      expect(() => apportionAcrossDays(30, const []),
          throwsA(isA<ApportionmentImpossible>()));
    });
  });

  group('TrackedEntry invariants', () {
    test('rejects a duration over one day', () {
      expect(
        () => TrackedEntry(
            id: 'x', taskName: 't', durationMinutes: 1441, logDate: '2026-08-25'),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects a half range', () {
      expect(
        () => TrackedEntry(
            id: 'x',
            taskName: 't',
            durationMinutes: 30,
            logDate: '2026-08-25',
            startLocal: '14:00'),
        throwsA(isA<AssertionError>()),
      );
    });

    test('toCreateMap omits absent optionals', () {
      final map = TrackedEntry(
              id: 'x',
              taskName: 'walking',
              durationMinutes: 30,
              logDate: '2026-08-25')
          .toCreateMap();
      expect(map.keys,
          containsAll(['taskName', 'durationMinutes', 'logDate']));
      expect(map.containsKey('startLocal'), isFalse);
      expect(map.containsKey('sourceItemId'), isFalse);
    });
  });

  group('deriveEndLocal', () {
    test('end = start + duration within the same day', () {
      expect(deriveEndLocal('14:00', 30), '14:30');
      expect(deriveEndLocal('14:00', 90), '15:30');
    });

    test('wraps past midnight to the next day', () {
      expect(deriveEndLocal('23:00', 90), '00:30');
      expect(deriveEndLocal('23:45', 30), '00:15');
    });

    test('a full-day duration lands back on the start time', () {
      expect(deriveEndLocal('09:00', 1440), '09:00');
    });

    test('a malformed start defaults to 0 rather than throwing', () {
      expect(deriveEndLocal('', 45), '00:45');
    });
  });

  group('logDateFor', () {
    test('unknown zone falls back to the UTC date rather than throwing', () {
      final d = logDateFor(DateTime.utc(2026, 8, 25, 10), 'Not/AZone');
      expect(d, '2026-08-25');
    });
  });
}
