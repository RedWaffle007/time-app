/// **The extensible stats vocabulary.** Adding a new statistic is adding one
/// entry to [kProfileStatDefinitions] — no screen, repository, rule or
/// migration changes.
///
/// The shape exists because of a constraint that is easy to miss until it bites:
/// **you cannot compute another user's stats on their behalf.** Their schedule
/// items live at `scheduleItems/{theirUid}/items` and the rules let only them
/// read that subtree — correctly, since it is their whole day. So a profile
/// visitor has no way to derive anything.
///
/// Therefore stats are **published**, not derived on read:
///
/// ```
///   my device                          another person's device
///   ─────────                          ───────────────────────
///   record providers                   users/{me}/profileStats/summary
///     (allItemsAsTarget…)     publish            │  read, if privacy allows
///           │                    ──▶  ┌──────────┴──────────┐
///           └── compute ─────────────▶│  values{ key: num } │
///                                     └─────────────────────┘
/// ```
///
/// Both paths end in `List<ProfileStat>`, so [StatsSection] renders my own
/// profile and a stranger's with the same widget and no branch.
///
/// **The one rule for a new stat:** its `compute` MUST read the record
/// providers (`allItemsAsTargetProvider` / `allItemsAsPlannerProvider`), never
/// the filtered `myItemsAs*` views. `schedule_providers.dart` states the
/// reasoning where it can be violated: archiving hides rows without changing
/// what happened, so a stat computed from a filtered view silently drops every
/// rejected and every archived item from the user's own numbers, with no error
/// to trace it by.
library;

import 'package:cloud_firestore/cloud_firestore.dart';

/// A percentage needs at least this many plans behind it (item 24b). Below
/// that it renders [ProfileStatState.insufficient] — "—" and the reason —
/// never a confident 100% from one plan.
const kMinStatSample = 5;

/// How a statistic should be rendered right now.
enum ProfileStatState {
  /// A real, computed number.
  ready,

  /// The stat is defined and its tile is drawn, but no tracker feeds it yet.
  /// Renders an em dash and a muted "Coming soon" caption.
  ///
  /// This is what makes the section extensible *visibly*: the tile exists from
  /// day one, so plugging a tracker in later changes a number, not a layout.
  placeholder,

  /// Withheld because the viewer is not allowed to see it. Distinct from
  /// [placeholder] on purpose — "not yet measured" and "not yours to see" are
  /// different messages and must never render identically.
  hidden,

  /// Measured, but too few plans stand behind it to be honest (a percentage
  /// below `kMinStatSample`). Renders an em dash and "After 5 answered plans".
  /// Distinct from [placeholder]: the feature exists, the sample does not.
  insufficient,
}

/// How to format a stat's raw number for display.
///
/// Deliberately NOT a `String Function(num)` on the definition: a formatter
/// needs the locale, which needs a `BuildContext`, which a domain file must not
/// hold. So the definition names a *kind* and the presentation layer owns the
/// rendering.
enum ProfileStatUnit {
  /// A plain count — tasks completed, days, items.
  count,

  /// Whole minutes, rendered as e.g. "12h 30m".
  minutes,

  /// A run of consecutive days.
  days,

  /// 0–100, rendered with a percent sign.
  percent,
}

/// One statistic, ready to render.
class ProfileStat {
  const ProfileStat({
    required this.key,
    required this.label,
    required this.unit,
    required this.state,
    this.value,
    this.caption,
  });

  /// Stable machine key. **Never renamed** — it is the map key inside the
  /// published document, so changing it orphans every user's stored value.
  final String key;

  /// Human label, e.g. "Tasks completed".
  final String label;

  final ProfileStatUnit unit;
  final ProfileStatState state;

  /// Null whenever [state] is not [ProfileStatState.ready].
  final num? value;

  /// Optional muted line under the label (e.g. "Set for you 90% · Self 80%").
  /// Already formatted by the presentation layer that built it.
  final String? caption;

  ProfileStat asPlaceholder() => ProfileStat(
    key: key,
    label: label,
    unit: unit,
    state: ProfileStatState.placeholder,
  );

  ProfileStat asHidden() => ProfileStat(
    key: key,
    label: label,
    unit: unit,
    state: ProfileStatState.hidden,
  );
}

/// The definition of a statistic: everything true about it that does not depend
/// on a particular user.
///
/// [compute] is nullable, and that nullability IS the placeholder mechanism. A
/// definition with no compute function is a tile the app draws and does not yet
/// fill — which is exactly what "build it modular with placeholders now" asks
/// for. Supplying the function later turns the tile live with no other edit.
class ProfileStatDefinition {
  const ProfileStatDefinition({
    required this.key,
    required this.label,
    required this.unit,
    this.compute,
    this.sampled = false,
  });

  final String key;
  final String label;
  final ProfileStatUnit unit;

  /// A sampled stat (a percentage) is omitted from the published map until
  /// [kMinStatSample] plans stand behind it, and a missing value renders as
  /// [ProfileStatState.insufficient] rather than a placeholder (item 24c).
  final bool sampled;

  /// Derives the value from the signed-in user's OWN record. A null FUNCTION
  /// makes a placeholder; a null RESULT means "not publishable yet" (below the
  /// sample) and the key is omitted, never written as zero.
  ///
  /// The input is intentionally a narrow, plain-Dart bundle ([StatInputs])
  /// rather than a `WidgetRef`: it keeps every stat a pure function, which is
  /// what lets `test/social_stats_test.dart` cover them with no Firebase and no
  /// widget tree.
  final num? Function(StatInputs inputs)? compute;

  bool get isPlaceholder => compute == null;
}

/// Everything a [ProfileStatDefinition.compute] is allowed to see.
///
/// Adding a field here is how a new data source (e.g. plan requests)
/// feeds the stats layer — the registry does not need to know where the data
/// came from, only that it arrived.
class StatInputs {
  const StatInputs({
    required this.itemsAsTarget,
    required this.itemsAsPlanner,
    required this.now,
    required this.timezone,
  });

  /// The RECORD, not a filtered view. See the library doc.
  final List<StatItem> itemsAsTarget;
  final List<StatItem> itemsAsPlanner;

  final DateTime now;

  /// The user's home IANA zone, needed by anything day-shaped (a streak has to
  /// know where midnight is).
  final String timezone;
}

/// The minimum a stat needs to know about a schedule item.
///
/// A deliberate narrowing rather than passing `ScheduleItem` straight through.
/// It keeps `social/` from depending on the whole scheduling domain, and it
/// means a future tracker that is not a schedule item at all can still feed
/// these functions by mapping into this shape.
class StatItem {
  const StatItem({
    required this.instantUtc,
    required this.isApproved,
    required this.isDone,
    required this.isSkipped,
    this.isSelfPlan = false,
    this.isCancelled = false,
    this.isMissed = false,
    this.wasUnavailable = false,
    this.creatorUid,
    this.fromPlanRequest = false,
  });

  final DateTime instantUtc;
  final bool isApproved;
  final bool isDone;
  final bool isSkipped;

  /// The user planned this for themselves (creator == target).
  final bool isSelfPlan;

  /// Cancelled by the planner, withdrawn or rejected — the alarm never stood,
  /// so it is not an alarm anyone "set".
  final bool isCancelled;

  /// Auto-skipped because nobody answered: the end-of-day lapse ("Did not
  /// respond") or the ring-cap timeout ("User unavailable"), with no later
  /// Done. Always also [isSkipped]. The one thing that breaks a streak.
  final bool isMissed;

  /// The alarm rang out unanswered (`alarm.unavailableAt`), whatever the
  /// outcome later became — a Done here is Done (Late).
  final bool wasUnavailable;

  /// Who set it. Null only in tests that do not care.
  final String? creatorUid;

  /// Created while fulfilling a friend's plan request (`planRequestId`).
  final bool fromPlanRequest;

  bool get hasOutcome => isDone || isSkipped;

  /// Skipped on purpose — a skip that is not [isMissed].
  bool get isDeliberateSkip => isSkipped && !isMissed;
}

/// The published stats document, `users/{uid}/profileStats/summary`.
///
/// [values] is an open map keyed by [ProfileStatDefinition.key]. Unknown keys
/// are IGNORED on read rather than treated as an error: an older build reading
/// a newer user's document must degrade to showing the stats it understands,
/// not fail. That is what makes adding a stat a non-breaking change.
class ProfileStatsSnapshot {
  const ProfileStatsSnapshot({
    required this.values,
    this.version = 1,
    this.updatedAt,
  });

  static const empty = ProfileStatsSnapshot(values: {});

  final Map<String, num> values;

  /// Bumped only if the MEANING of an existing key changes — which is a thing
  /// to avoid doing. A new key needs no bump.
  final int version;

  final DateTime? updatedAt;

  factory ProfileStatsSnapshot.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data() ?? const {};
    final raw = d['values'];
    return ProfileStatsSnapshot(
      values: raw is Map
          ? {
              for (final e in raw.entries)
                if (e.key is String && e.value is num)
                  e.key as String: e.value as num,
            }
          : const {},
      version: (d['version'] as num?)?.toInt() ?? 1,
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
