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
  }) {
    // Karachi is UTC+5 year-round, so subtracting five hours gives the instant.
    final utc = DateTime.utc(year, month, day, hour - 5);
    return StatItem(
      instantUtc: utc,
      isApproved: approved,
      isDone: done,
      isSkipped: skipped,
    );
  }

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

    test('ships both live stats and placeholders', () {
      // The mechanism the feature was asked for: a tile that exists now and
      // fills in later without a refactor.
      expect(kProfileStatDefinitions.any((d) => d.compute != null), isTrue);
      expect(kProfileStatDefinitions.any((d) => d.isPlaceholder), isTrue);
    });

    test('placeholders are NOT published as zero', () {
      // A stored `hoursTracked: 0` is indistinguishable from a measured zero,
      // so a visitor's device would render a confident, wrong number.
      final values = computeStatValues(inputs());
      for (final def in kProfileStatDefinitions.where((d) => d.isPlaceholder)) {
        expect(values.containsKey(def.key), isFalse, reason: def.key);
      }
    });

    test('a stat with no stored value renders as a placeholder tile', () {
      final stats = statsFromSnapshot(const ProfileStatsSnapshot(values: {}));
      expect(stats.length, kProfileStatDefinitions.length);
      expect(
        stats.every((s) => s.state == ProfileStatState.placeholder),
        isTrue,
      );
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
      final values = computeStatValues(inputs(target: [
        at(2026, 8, 20, done: true),
        at(2026, 8, 19, done: true),
        at(2026, 8, 18, skipped: true),
        at(2026, 8, 17),
      ]));
      expect(values['tasksCompleted'], 2);
    });
  });

  group('followThrough', () {
    test('is done over everything that reached an outcome', () {
      final values = computeStatValues(inputs(target: [
        at(2026, 8, 20, done: true),
        at(2026, 8, 19, done: true),
        at(2026, 8, 18, done: true),
        at(2026, 8, 17, skipped: true),
      ]));
      expect(values['followThrough'], 75);
    });

    test('an approved future item does NOT count against you', () {
      // The denominator is settled items, not everything approved — otherwise
      // the number would fall every time someone planned ahead, punishing the
      // exact behaviour the app exists to encourage.
      final withPlans = computeStatValues(inputs(target: [
        at(2026, 8, 20, done: true),
        at(2026, 12, 25), // approved, not yet due
        at(2026, 12, 26),
      ]));
      expect(withPlans['followThrough'], 100);
    });

    test('reads zero with no outcomes at all', () {
      expect(computeStatValues(inputs())['followThrough'], 0);
    });
  });

  group('currentStreak', () {
    test('counts consecutive days ending today', () {
      final values = computeStatValues(inputs(target: [
        at(2026, 8, 21, done: true),
        at(2026, 8, 20, done: true),
        at(2026, 8, 19, done: true),
      ]));
      expect(values['currentStreak'], 3);
    });

    test('survives a today with nothing done yet', () {
      // The streak must not break at midnight while the user is asleep and
      // reappear when they complete something the next morning.
      final values = computeStatValues(inputs(target: [
        at(2026, 8, 20, done: true),
        at(2026, 8, 19, done: true),
      ]));
      expect(values['currentStreak'], 2);
    });

    test('breaks once the run ended before yesterday', () {
      final values = computeStatValues(inputs(target: [
        at(2026, 8, 18, done: true),
        at(2026, 8, 17, done: true),
      ]));
      expect(values['currentStreak'], 0);
    });

    test('a gap ends the run — only the CURRENT streak counts', () {
      final values = computeStatValues(inputs(target: [
        at(2026, 8, 21, done: true),
        at(2026, 8, 20, done: true),
        // 19th missing.
        at(2026, 8, 18, done: true),
        at(2026, 8, 17, done: true),
        at(2026, 8, 16, done: true),
      ]));
      expect(values['currentStreak'], 2);
    });

    test('several completions on one day count once', () {
      final values = computeStatValues(inputs(target: [
        at(2026, 8, 21, hour: 9, done: true),
        at(2026, 8, 21, hour: 14, done: true),
        at(2026, 8, 21, hour: 20, done: true),
      ]));
      expect(values['currentStreak'], 1);
    });

    test('skipped items do not extend a streak', () {
      final values = computeStatValues(inputs(target: [
        at(2026, 8, 21, done: true),
        at(2026, 8, 20, skipped: true),
        at(2026, 8, 19, done: true),
      ]));
      expect(values['currentStreak'], 1);
    });

    test('day boundaries follow the HOME zone, not UTC', () {
      // 02:00 on the 21st in Karachi is 21:00 on the 20th in UTC. Counting in
      // UTC would put these two completions on different days and report a
      // 2-day streak where the person lived one.
      final lateNight = StatItem(
        instantUtc: DateTime.utc(2026, 8, 20, 21),
        isApproved: true,
        isDone: true,
        isSkipped: false,
      );
      final sameDayMorning = at(2026, 8, 21, hour: 9, done: true);

      final values = computeStatValues(
        inputs(target: [lateNight, sameDayMorning]),
      );
      expect(values['currentStreak'], 1);
    });

    test('an unknown timezone yields no streak rather than throwing', () {
      // A bad zone must not take down a whole profile's stats pass.
      final values = computeStatValues(inputs(
        target: [at(2026, 8, 21, done: true)],
        timezone: 'Not/AZone',
      ));
      expect(values['currentStreak'], 0);
    });

    test('empty history is zero', () {
      expect(computeStatValues(inputs())['currentStreak'], 0);
    });
  });

  group('plansCreated', () {
    test('counts what the user planned for other people', () {
      final values = computeStatValues(inputs(
        planner: [at(2026, 8, 20), at(2026, 8, 19), at(2026, 8, 18)],
      ));
      expect(values['plansCreated'], 3);
    });
  });
}
