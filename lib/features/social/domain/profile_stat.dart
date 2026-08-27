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
  });

  final String key;
  final String label;
  final ProfileStatUnit unit;

  /// Derives the value from the signed-in user's OWN record. Null → placeholder.
  ///
  /// The input is intentionally a narrow, plain-Dart bundle ([StatInputs])
  /// rather than a `WidgetRef`: it keeps every stat a pure function, which is
  /// what lets `test/social_stats_test.dart` cover them with no Firebase and no
  /// widget tree.
  final num Function(StatInputs inputs)? compute;

  bool get isPlaceholder => compute == null;
}

/// Everything a [ProfileStatDefinition.compute] is allowed to see.
///
/// Adding a field here is how a future tracker (hours logged, sessions, goals)
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
    this.completedAt,
  });

  final DateTime instantUtc;
  final bool isApproved;
  final bool isDone;
  final bool isSkipped;

  /// When a DONE item was actually completed. Null on non-done items and on
  /// legacy done items that predate the field. Combined with [instantUtc] it is
  /// the whole delay story — see [wasLate] / [latenessMinutes].
  final DateTime? completedAt;

  bool get hasOutcome => isDone || isSkipped;

  /// Completed after its scheduled time. A done item with no [completedAt]
  /// (legacy) is treated as on-time, not guessed late.
  bool get wasLate =>
      isDone && completedAt != null && completedAt!.isAfter(instantUtc);

  /// How many whole minutes late, or 0 when on time / not applicable.
  int get latenessMinutes =>
      wasLate ? completedAt!.difference(instantUtc).inMinutes : 0;
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
