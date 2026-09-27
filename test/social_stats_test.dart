import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/social/application/stats_registry.dart';
import 'package:time_app/features/social/domain/profile_stat.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// The stats registry — the extensible half of the profile.
///
/// Every computation is a pure function over [StatInputs] with an injected
/// `now`, which is exactly what makes this file possible: no Firestore, no
/// device, no clock of its own. The streak tests in particular would be
/// untestable if the function reached for `DateTime.now()` itself.
void main() {
  // The streak counts days in the user's HOME timezone, so the zone database
  // has to be loaded — the same call `main.dart` makes at startup.
  setUpAll(tzdata.initializeTimeZones);

  const zone = 'Asia/Karachi'; // UTC+5, no DST — a clean day boundary.

  /// An item at a given local wall time in [zone].
  StatItem at(
    int year,
    int month,
    int day, {
    int hour = 12,
    bool done = false,
    bool skipped = false,
    bool approved = true,
    bool self = false,
    bool cancelled = false,
  }) {
    // Karachi is UTC+5 year-round, so subtracting five hours gives the instant.
    final utc = DateTime.utc(year, month, day, hour - 5);
    return StatItem(
      instantUtc: utc,
      isApproved: approved,
      isDone: done,
      isSkipped: skipped,
      isSelfPlan: self,
      isCancelled: cancelled,
    );
  }

  StatItem missedAt(int year, int month, int day) => StatItem(
    instantUtc: DateTime.utc(year, month, day, 7),
    isApproved: true,
    isDone: false,
    isSkipped: true,
    isMissed: true,
  );

  StatInputs inputs({
    List<StatItem> target = const [],
    List<StatItem> planner = const [],
    DateTime? now,
    String timezone = zone,
  }) {
    return StatInputs(
      itemsAsTarget: target,
      itemsAsPlanner: planner,
      now: now ?? DateTime.utc(2026, 8, 21, 7), // 12:00 in Karachi
      timezone: timezone,
    );
  }

  group('registry shape', () {
    test('keys are unique — they are document map keys', () {
      final keys = kProfileStatDefinitions.map((d) => d.key).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('ships live stats and no "Coming soon" tile (item 24a)', () {
      // A placeholder advertised a feature that does not exist ("Goals
      // achieved"). The mechanism stays — see the empty-snapshot test below —
      // but nothing ships as one.
      expect(kProfileStatDefinitions.any((d) => d.compute != null), isTrue);
      expect(kProfileStatDefinitions.any((d) => d.isPlaceholder), isFalse);
      expect(
        kProfileStatDefinitions.map((d) => d.key),
        isNot(contains('goalsAchieved')),
      );
    });

    test('placeholders are NOT published as zero', () {
      // A stored zero is indistinguishable from a measured zero,
      // so a visitor's device would render a confident, wrong number.
      final values = computeStatValues(inputs());
      for (final def in kProfileStatDefinitions.where((d) => d.isPlaceholder)) {
        expect(values.containsKey(def.key), isFalse, reason: def.key);
      }
    });

    test('a missing value: sampled → insufficient, others → placeholder', () {
      final stats = statsFromSnapshot(const ProfileStatsSnapshot(values: {}));
      expect(stats.length, kProfileStatDefinitions.length);
      for (final stat in stats) {
        final def = kProfileStatDefinitions.firstWhere(
          (d) => d.key == stat.key,
        );
        expect(
          stat.state,
          def.sampled
              ? ProfileStatState.insufficient
              : ProfileStatState.placeholder,
          reason: stat.key,
        );
      }
    });

    test('an UNKNOWN stored key is ignored, not an error', () {
      // An older build reading a newer user's document must degrade to showing
      // what it understands. This is what makes adding a stat non-breaking.
      final stats = statsFromSnapshot(
        const ProfileStatsSnapshot(
          values: {'tasksCompleted': 4, 'somethingFromTheFuture': 99},
        ),
      );
      expect(stats.length, kProfileStatDefinitions.length);
      final completed = stats.firstWhere((s) => s.key == 'tasksCompleted');
      expect(completed.state, ProfileStatState.ready);
      expect(completed.value, 4);
    });

    test('hidden stats keep every tile, withheld', () {
      final hidden = hiddenStats();
      expect(hidden.length, kProfileStatDefinitions.length);
      expect(hidden.every((s) => s.state == ProfileStatState.hidden), isTrue);
      expect(hidden.every((s) => s.value == null), isTrue);
    });
  });

  group('tasksCompleted', () {
    test('counts done items only', () {
      final values = computeStatValues(
        inputs(
          target: [
            at(2026, 8, 20, done: true),
            at(2026, 8, 19, done: true),
            at(2026, 8, 18, skipped: true),
            at(2026, 8, 17),
          ],
        ),
      );
      expect(values['tasksCompleted'], 2);
    });
  });

  group('followThrough (sampled, item 24c)', () {
    test('is done over everything answered, once five are answered', () {
      final values = computeStatValues(
        inputs(
          target: [
            at(2026, 8, 20, done: true),
            at(2026, 8, 19, done: true),
            at(2026, 8, 18, done: true),
            at(2026, 8, 17, skipped: true),
            missedAt(2026, 8, 16),
          ],
        ),
      );
      expect(values['followThrough'], 60);
    });

    test('below five answered it is NOT published — never 0% or 100%', () {
      final values = computeStatValues(
        inputs(
          target: [for (var d = 17; d <= 20; d++) at(2026, 8, d, done: true)],
        ),
      );
      expect(values.containsKey('followThrough'), isFalse);
      expect(computeStatValues(inputs()).containsKey('followThrough'), false);
    });

    test('an upcoming plan does NOT count against you', () {
      final values = computeStatValues(
        inputs(
          target: [
            for (var d = 16; d <= 20; d++) at(2026, 8, d, done: true),
            at(2026, 12, 25), // approved, not yet due
          ],
        ),
      );
      expect(values['followThrough'], 100);
    });

    test('cancelled plans count nowhere', () {
      final values = computeStatValues(
        inputs(
          target: [
            for (var d = 16; d <= 20; d++) at(2026, 8, d, done: true),
            at(2026, 8, 15, skipped: true, cancelled: true),
          ],
        ),
      );
      expect(values['followThrough'], 100);
    });
  });

  group('bestStreak', () {
    test('is the longest humane run in history', () {
      final values = computeStatValues(
        inputs(
          target: [
            at(2026, 8, 21, done: true),
            missedAt(2026, 8, 20),
            for (var d = 14; d <= 17; d++) at(2026, 8, d, done: true),
          ],
        ),
      );
      expect(values['currentStreak'], 1);
      expect(values['bestStreak'], 4);
    });
  });

  group('currentStreak (humane rule, item 24b)', () {
    test('counts consecutive done days', () {
      final values = computeStatValues(
        inputs(
          target: [
            at(2026, 8, 21, done: true),
            at(2026, 8, 20, done: true),
            at(2026, 8, 19, done: true),
          ],
        ),
      );
      expect(values['currentStreak'], 3);
    });

    test('a plan-less gap is neutral — rest days never cost a streak', () {
      final values = computeStatValues(
        inputs(
          target: [
            at(2026, 8, 21, done: true),
            // 19th and 20th: nothing planned.
            at(2026, 8, 18, done: true),
            at(2026, 8, 17, done: true),
          ],
        ),
      );
      expect(values['currentStreak'], 3);
    });

    test('a missed plan breaks the run', () {
      final values = computeStatValues(
        inputs(
          target: [
            at(2026, 8, 21, done: true),
            at(2026, 8, 20, done: true),
            missedAt(2026, 8, 19),
            at(2026, 8, 18, done: true),
          ],
        ),
      );
      expect(values['currentStreak'], 2);
    });

    test('a deliberate skip is neutral', () {
      final values = computeStatValues(
        inputs(
          target: [
            at(2026, 8, 21, done: true),
            at(2026, 8, 20, skipped: true),
            at(2026, 8, 19, done: true),
          ],
        ),
      );
      expect(values['currentStreak'], 2);
    });

    test('day boundaries follow the HOME zone, not UTC', () {
      // 02:00 on the 21st in Karachi is 21:00 on the 20th in UTC.
      final lateNight = StatItem(
        instantUtc: DateTime.utc(2026, 8, 20, 21),
        isApproved: true,
        isDone: true,
        isSkipped: false,
      );
      final values = computeStatValues(
        inputs(target: [lateNight, at(2026, 8, 21, hour: 9, done: true)]),
      );
      expect(values['currentStreak'], 1);
    });

    test('an unknown timezone yields no streak rather than throwing', () {
      final values = computeStatValues(
        inputs(target: [at(2026, 8, 21, done: true)], timezone: 'Not/AZone'),
      );
      expect(values['currentStreak'], 0);
    });

    test('empty history is zero', () {
      expect(computeStatValues(inputs())['currentStreak'], 0);
    });
  });

  group('what a profile may show (item 24c)', () {
    test('exactly the humane four — nothing else is ever published', () {
      final values = computeStatValues(
        inputs(
          target: [
            for (var d = 15; d <= 20; d++) at(2026, 8, d, done: true),
            missedAt(2026, 8, 14),
          ],
          planner: [at(2026, 8, 20), at(2026, 8, 19)],
        ),
      );
      expect(values.keys.toSet(), {
        'tasksCompleted',
        'currentStreak',
        'bestStreak',
        'followThrough',
      });
    });

    test('private-page stats never enter the registry', () {
      final keys = kProfileStatDefinitions.map((d) => d.key).toSet();
      for (final private in [
        'plansCreated',
        'missed',
        'answeredWhenRang',
        'topPlanners',
        'setForYou',
        'alarmsSet',
        'requestsFulfilled',
        'onTimeRate',
        'avgLateMinutes',
      ]) {
        expect(keys, isNot(contains(private)), reason: private);
      }
    });

    test('only percentages are sampled', () {
      for (final def in kProfileStatDefinitions) {
        expect(
          def.sampled,
          def.unit == ProfileStatUnit.percent,
          reason: def.key,
        );
      }
    });
  });

  test('On-time rate and Avg late by are gone (item 24a)', () {
    // Under the ringing-alarm model they measured the ring, not the person:
    // a Done tapped while the alarm rings always lands after the instant.
    final keys = kProfileStatDefinitions.map((d) => d.key).toSet();
    expect(keys, isNot(contains('onTimeRate')));
    expect(keys, isNot(contains('avgLateMinutes')));
    final values = computeStatValues(
      inputs(target: [at(2026, 8, 20, done: true)]),
    );
    expect(values.containsKey('onTimeRate'), isFalse);
    expect(values.containsKey('avgLateMinutes'), isFalse);
  });

  test('Track Time\'s stats are gone (item 8, 2026-09-27)', () {
    final keys = kProfileStatDefinitions.map((d) => d.key).toSet();
    expect(keys, isNot(contains('hoursTracked')));
    expect(keys, isNot(contains('focusSessions')));
    final values = computeStatValues(inputs());
    expect(values.containsKey('hoursTracked'), isFalse);
    expect(values.containsKey('focusSessions'), isFalse);
  });
}
