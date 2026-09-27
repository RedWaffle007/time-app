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
/// record.
///
/// **This list IS what other people may see** (item 24c, DECISIONS.md "24c —
/// what a profile shows"): friends always, anyone when the profile is public,
/// and group members via `memberStats`. It is deliberately the small, humane
/// subset — effort and consistency, never failure detail. Missed alarms,
/// lateness, who plans for you and how often you plan for others stay on the
/// private Stats page (`buildMyStats`) and are NEVER added here.
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
    key: 'bestStreak',
    label: 'Best streak',
    unit: ProfileStatUnit.days,
    compute: _bestStreak,
  ),
  ProfileStatDefinition(
    key: 'followThrough',
    label: 'Follow-through',
    unit: ProfileStatUnit.percent,
    compute: _followThrough,
    sampled: true,
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
      def.key: ?def.compute?.call(inputs),
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
          state: def.sampled
              ? ProfileStatState.insufficient
              : ProfileStatState.placeholder,
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

/// Done as a share of everything answered — done + skipped, where skipped
/// includes missed (a deliberate Skip counts against follow-through, item
/// 24b). An upcoming plan is not a broken commitment and is not counted.
///
/// Null — so NOT published — below [kMinStatSample] answered plans: 1 of 1 is
/// not "100%" to anyone reading a profile.
num? _followThrough(StatInputs i) {
  final settled = i.itemsAsTarget
      .where((it) => !it.isCancelled && it.hasOutcome)
      .length;
  if (settled < kMinStatSample) return null;
  final done = i.itemsAsTarget
      .where((it) => !it.isCancelled && it.isDone)
      .length;
  return ((done / settled) * 100).round();
}

/// The humane current streak (item 24b) — the same function the Stats page
/// uses, so a profile and the dashboard can never disagree. See
/// [computeStreaks] for the rule.
num _currentStreak(StatInputs i) =>
    computeStreaks(i.itemsAsTarget, i.timezone).current;

/// The longest run under the same humane rule.
num _bestStreak(StatInputs i) =>
    computeStreaks(i.itemsAsTarget, i.timezone).best;
