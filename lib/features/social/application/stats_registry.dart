import 'package:timezone/timezone.dart' as tz;

import '../domain/profile_stat.dart';

/// **The stats registry — the one list of what a profile can show.**
///
/// This is the extension point the whole stats section exists to provide. To
/// add a statistic later (hours tracked, focus sessions, goal completion), add
/// one [ProfileStatDefinition] here. Nothing else changes: the tile renders,
/// the value publishes, another user's device reads it, and the privacy gate
/// covers it — all off this list.
///
/// To turn an existing PLACEHOLDER into a live stat, give it a `compute`
/// function. That is the only edit. The tile, the key, the label and the
/// published-document slot already exist, which is the point of shipping the
/// placeholders now rather than leaving gaps to be designed into later.
///
/// **Order is display order.** The first four are live off the delegation loop
/// that already ships; the rest are the tracker stats named for future
/// sessions, drawn as tiles and waiting for a source.
const List<ProfileStatDefinition> kProfileStatDefinitions = [
  // ---- live today, computed from the schedule record ----
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
  ProfileStatDefinition(
    key: 'onTimeRate',
    label: 'On-time rate',
    unit: ProfileStatUnit.percent,
    compute: _onTimeRate,
  ),
  ProfileStatDefinition(
    key: 'avgLateMinutes',
    label: 'Avg late by',
    unit: ProfileStatUnit.minutes,
    compute: _avgLateMinutes,
  ),
  ProfileStatDefinition(
    key: 'plansCreated',
    label: 'Plans made for others',
    unit: ProfileStatUnit.count,
    compute: _plansCreated,
  ),

  // ---- placeholders: defined, drawn, not yet fed ----
  //
  // These have no `compute`, which is what marks them placeholder. They are
  // NOT parked-feature scaffolding: no tracker logic, no config flag and no
  // dormant code path is introduced by naming a tile. They are the schema and
  // the layout, settled now so that plugging a tracker in later is one function
  // rather than a redesign.
  ProfileStatDefinition(
    key: 'hoursTracked',
    label: 'Time tracked',
    unit: ProfileStatUnit.minutes,
  ),
  ProfileStatDefinition(
    key: 'focusSessions',
    label: 'Focus sessions',
    unit: ProfileStatUnit.count,
  ),
  ProfileStatDefinition(
    key: 'goalsAchieved',
    label: 'Goals achieved',
    unit: ProfileStatUnit.count,
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

num _plansCreated(StatInputs i) => i.itemsAsPlanner.length;

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

/// Of the tasks the user COMPLETED, the share finished at or before their
/// scheduled time. A late completion is honest data, counted here as not-on-time
/// rather than dropped. Denominator is done items only — a skip is a different
/// failure that [_followThrough] already captures, and an approved item whose
/// time has not arrived is neither on-time nor late yet.
///
/// A done item with no `completedAt` (legacy) counts as on-time — [StatItem]
/// declines to guess lateness it cannot measure. Returns 0 with nothing done.
num _onTimeRate(StatInputs i) {
  final done = i.itemsAsTarget.where((it) => it.isDone).toList();
  if (done.isEmpty) return 0;
  final onTime = done.where((it) => !it.wasLate).length;
  return ((onTime / done.length) * 100).round();
}

/// The average lateness (whole minutes) across the completions that WERE late.
/// The denominator is late items only, so it reads "when late, typically by
/// this much" rather than being diluted by every on-time task. 0 when nothing
/// was ever late — a meaningful "never late", and the section stays suppressed
/// until there is history anyway.
num _avgLateMinutes(StatInputs i) {
  final late = i.itemsAsTarget.where((it) => it.wasLate).toList();
  if (late.isEmpty) return 0;
  final total = late.fold<int>(0, (sum, it) => sum + it.latenessMinutes);
  return (total / late.length).round();
}

/// Consecutive days, ending today or yesterday, on which at least one item was
/// completed.
///
/// **Days are counted in the user's home timezone**, not UTC and not the
/// device's current zone. A streak is a lived thing — it breaks at the
/// midnight the person actually slept through — and the app already anchors
/// every commitment to `homeTimezone` for exactly this reason.
///
/// Ending "today or yesterday" is deliberate: a streak must not break at
/// midnight while the user is asleep and reappear when they complete something
/// the next morning. Today counts if it has a completion; if it does not, the
/// run is measured back from yesterday and stays intact for the whole day.
num _currentStreak(StatInputs i) {
  if (i.itemsAsTarget.isEmpty) return 0;

  final tz.Location location;
  try {
    location = tz.getLocation(i.timezone);
  } catch (_) {
    // An unknown or empty zone must not throw inside a stats pass and take the
    // whole profile down. No zone means no honest day boundary, so no streak.
    return 0;
  }

  int dayNumber(DateTime utc) {
    final local = tz.TZDateTime.from(utc, location);
    // Days since the epoch in local terms. DateTime.utc on the local Y/M/D is
    // the standard trick for a calendar-day ordinal that is immune to the
    // zone's own offset — including across a DST shift, where a local day is
    // 23 or 25 hours long but still exactly one day.
    return DateTime.utc(local.year, local.month, local.day)
            .difference(DateTime.utc(1970, 1, 1))
            .inDays;
  }

  final completedDays = <int>{
    for (final item in i.itemsAsTarget)
      if (item.isDone) dayNumber(item.instantUtc),
  };
  if (completedDays.isEmpty) return 0;

  final today = dayNumber(i.now);
  // Anchor on today if it has a completion, otherwise on yesterday. Anything
  // older means the run has already ended.
  var cursor = completedDays.contains(today) ? today : today - 1;
  if (!completedDays.contains(cursor)) return 0;

  var streak = 0;
  while (completedDays.contains(cursor)) {
    streak++;
    cursor--;
  }
  return streak;
}
