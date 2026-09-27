import '../domain/profile_stat.dart';
import 'streak_policy.dart';

/// **The stats registry — the one list of what a profile can show.**
///
/// This is the extension point the whole stats section exists to provide. To
/// add a statistic, add one [ProfileStatDefinition] here. Nothing else changes:
/// the tile renders, the value publishes, another user's device reads it, and
/// the privacy gate covers it — all off this list.
///
/// A definition with no `compute` is a PLACEHOLDER tile (drawn, never
/// published). None ships today: a tile for a feature that does not exist
/// ("Goals achieved") was removed in item 24a. The mechanism stays.
///
/// **Order is display order.** Every stat is computed from the schedule
/// record. "On-time rate" and "Avg late by" were removed in item 24a: under
/// the ringing-alarm model they measured the ring, not the person (DECISIONS.md
/// "Stats review — findings and decisions").
const List<ProfileStatDefinition> kProfileStatDefinitions = [
  ProfileStatDefinition(
    key: 'tasksCompleted',
    label: 'Tasks completed',
    unit: ProfileStatUnit.count,
    compute: _tasksCompleted,
  ),
  ProfileStatDefinition(
    key: 'currentStreak',
    label: 'Current streak',
    unit: ProfileStatUnit.days,
    compute: _currentStreak,
  ),
  ProfileStatDefinition(
    key: 'followThrough',
    label: 'Follow-through',
    unit: ProfileStatUnit.percent,
    compute: _followThrough,
  ),
  // The key predates the rename and is never renamed (it is a published map
  // key); the label says what it counts.
  ProfileStatDefinition(
    key: 'plansCreated',
    label: 'Alarms you set for others',
    unit: ProfileStatUnit.count,
    compute: _plansCreated,
  ),
];

/// Every stat's value for the signed-in user, ready to publish.
///
/// Placeholders are omitted entirely rather than published as zero. A stored
/// `hoursTracked: 0` is indistinguishable from a real measured zero, so a
/// viewer's device could not tell "nothing tracked yet" from "tracked nothing",
/// and the tile would render a confident, wrong number.
Map<String, num> computeStatValues(StatInputs inputs) {
  return {
    for (final def in kProfileStatDefinitions)
      if (def.compute != null) def.key: def.compute!(inputs),
  };
}

/// Turn a published [snapshot] into the list the UI renders.
///
/// A definition with no stored value renders as a placeholder — which covers
/// both "this stat has no source yet" and "this profile was last published by a
/// build that did not know this stat". Both are honestly "no number here".
List<ProfileStat> statsFromSnapshot(ProfileStatsSnapshot snapshot) {
  return [
    for (final def in kProfileStatDefinitions)
      if (snapshot.values[def.key] case final value?)
        ProfileStat(
          key: def.key,
          label: def.label,
          unit: def.unit,
          state: ProfileStatState.ready,
          value: value,
        )
      else
        ProfileStat(
          key: def.key,
          label: def.label,
          unit: def.unit,
          state: ProfileStatState.placeholder,
        ),
  ];
}

/// The list to render when the viewer may not see this profile's numbers.
///
/// Every tile still appears, withheld. Drawing the section but not the values
/// says "there is something here you cannot see", which is the truth; hiding
/// the section entirely would be indistinguishable from a profile with no
/// activity at all.
List<ProfileStat> hiddenStats() => [
  for (final def in kProfileStatDefinitions)
    ProfileStat(
      key: def.key,
      label: def.label,
      unit: def.unit,
      state: ProfileStatState.hidden,
    ),
];

// ---------------------------------------------------------------------------
// The computations. Pure functions over [StatInputs] — no clock of their own,
// no Firestore, no context — which is what `test/social_stats_test.dart`
// exercises.
// ---------------------------------------------------------------------------

num _tasksCompleted(StatInputs i) =>
    i.itemsAsTarget.where((it) => it.isDone).length;

/// Alarms the user set for OTHER people that actually stood: self-plans are
/// not "for others", and a cancelled/withdrawn/rejected plan never rang.
num _plansCreated(StatInputs i) =>
    i.itemsAsPlanner.where((it) => !it.isSelfPlan && !it.isCancelled).length;

/// Done as a share of everything that reached an outcome.
///
/// The denominator is done + skipped, NOT everything approved. An approved item
/// whose time has not arrived is not a broken commitment, and counting it as
/// one would make the number fall every time someone plans ahead — punishing
/// exactly the behaviour the app is for.
///
/// Returns 0 with no outcomes yet. The tile shows 0% only once there is at
/// least one, because [computeStatValues] publishes it either way; a profile
/// with no history reads 0% for a moment, which is why the empty state on the
/// section suppresses the whole block until something has happened.
num _followThrough(StatInputs i) {
  final settled = i.itemsAsTarget.where((it) => it.hasOutcome).length;
  if (settled == 0) return 0;
  final done = i.itemsAsTarget.where((it) => it.isDone).length;
  return ((done / settled) * 100).round();
}

/// The humane current streak (item 24b) — the same function the Stats page
/// uses, so a profile and the dashboard can never disagree. See
/// [computeStreaks] for the rule.
num _currentStreak(StatInputs i) =>
    computeStreaks(i.itemsAsTarget, i.timezone).current;
