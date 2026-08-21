import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../domain/profile_stat.dart';
import '../domain/profile_visibility.dart';
import 'social_providers.dart';
import 'stats_registry.dart';

// ---------------------------------------------------------------------------
// Computing MY stats.
// ---------------------------------------------------------------------------

/// Map the scheduling domain into the narrow shape the stats layer sees.
///
/// A deliberate narrowing (see [StatItem]): it keeps `social/` from depending
/// on the whole scheduling domain, and it is the seam a future tracker feeds
/// through without becoming a schedule item.
StatItem _toStatItem(ScheduleItem item) => StatItem(
      instantUtc: item.scheduledInstantUtc,
      isApproved: item.status == ScheduleItemStatus.approved,
      isDone: item.outcome?.result == OutcomeResult.done,
      isSkipped: item.outcome?.result == OutcomeResult.skipped,
    );

/// The signed-in user's freshly computed stat values.
///
/// **Reads the RECORD providers, never the filtered views**, which is the one
/// rule `schedule_providers.dart` states where it can be violated: archiving
/// hides rows without changing what happened, so computing from `myItemsAs*`
/// would silently drop every rejected item and everything the user archived out
/// of their own numbers, with nothing to trace it by. This is the first
/// record-layer consumer in the app; that comment was written for it.
final myComputedStatsProvider = Provider<AsyncValue<Map<String, num>>>((ref) {
  final asTarget = ref.watch(allItemsAsTargetProvider);
  final asPlanner = ref.watch(allItemsAsPlannerProvider);
  final profile = ref.watch(profileProvider);

  if (asTarget.hasError) {
    return AsyncError(asTarget.error!, asTarget.stackTrace ?? StackTrace.empty);
  }
  if (asPlanner.hasError) {
    return AsyncError(
        asPlanner.error!, asPlanner.stackTrace ?? StackTrace.empty);
  }

  final target = asTarget.value;
  final planner = asPlanner.value;
  final home = profile.value?.homeTimezone;
  if (target == null || planner == null || home == null) {
    return const AsyncLoading();
  }

  return AsyncData(
    computeStatValues(
      StatInputs(
        itemsAsTarget: target.map(_toStatItem).toList(),
        itemsAsPlanner: planner.map(_toStatItem).toList(),
        // A real clock, on purpose: the streak has to know what "today" is, and
        // the pure function it feeds takes `now` as an argument precisely so
        // the impurity stops here and the computation stays testable.
        now: DateTime.now().toUtc(),
        timezone: home,
      ),
    ),
  );
});

/// Publishes the signed-in user's stats so other people's devices can read
/// them. See [ProfileStatsRepository] for why publishing is necessary at all.
///
/// **Driven off the item stream, never off transitions** — the same rule the
/// reminder layer states and for the same reason. There is no hook in
/// `markDone()`, `approve()` or anywhere else: one recomputation is applied to
/// whatever the stream currently says, so an outcome, an edit, a withdrawal and
/// a rejection are not special cases. Adding a per-transition `publishStats()`
/// call anywhere would create a second place that decides, and the two would
/// disagree.
///
/// [publishIfChanged] is idempotent, which is what makes it safe to call on
/// every emission, every app start and every resume.
class ProfileStatsPublisher {
  ProfileStatsPublisher(this._ref);

  final Ref _ref;

  /// The last values successfully written, so an unchanged recomputation costs
  /// nothing. Firestore streams re-emit on every local write and on every
  /// metadata change, so without this a single completed task would publish
  /// several times.
  Map<String, num>? _lastPublished;

  Future<void> publishIfChanged() async {
    final uid = _ref.read(currentUidProvider);
    if (uid == null) return;

    final values = _ref.read(myComputedStatsProvider).value;
    if (values == null) return; // Still loading, or unreadable — try later.

    final previous = _lastPublished;
    if (previous != null && _sameValues(previous, values)) return;

    try {
      await _ref
          .read(profileStatsRepositoryProvider)
          .publish(uid: uid, values: values);
      _lastPublished = values;
    } catch (_) {
      // Best-effort, exactly like the push notifier: a failure here means
      // someone else's view of my numbers is stale, never that my own data is
      // wrong. The record is untouched and my own profile computes locally.
      // Leaving _lastPublished unset means the next emission retries.
    }
  }

  /// Forget what was published — called on sign-out, so the next account's
  /// first computation is not compared against the previous account's numbers
  /// and skipped as "unchanged".
  void reset() => _lastPublished = null;

  static bool _sameValues(Map<String, num> a, Map<String, num> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}

final profileStatsPublisherProvider = Provider<ProfileStatsPublisher>((ref) {
  return ProfileStatsPublisher(ref);
});

// ---------------------------------------------------------------------------
// Reading SOMEONE's stats, through the privacy gate.
// ---------------------------------------------------------------------------

/// The stats to render on [uid]'s profile, already resolved against privacy.
///
/// Three outcomes, and they must stay distinguishable:
///
///   * **the viewer may look** — real values, with a placeholder tile for every
///     stat that has no source yet;
///   * **the viewer may not look** — every tile withheld ([hiddenStats]), so the
///     section still says "there is something here", which is true;
///   * **still deciding** — loading. Never a permissive default: showing
///     numbers while the gate resolves would leak them for a frame.
///
/// For the user's own profile the values come from [myComputedStatsProvider]
/// rather than the published document, so their own numbers are live the
/// instant they complete something — no publish round-trip to wait through.
final profileStatsProvider =
    Provider.family<AsyncValue<List<ProfileStat>>, String>((ref, uid) {
  final visibility = ref.watch(profileVisibilityProvider(uid));

  return visibility.when(
    loading: () => const AsyncLoading(),
    error: (e, st) => AsyncError(e, st),
    data: (v) {
      if (!v.canSeeStats) return AsyncData(hiddenStats());

      if (v.relation == ProfileRelation.self) {
        return ref.watch(myComputedStatsProvider).whenData(
              (values) => statsFromSnapshot(ProfileStatsSnapshot(values: values)),
            );
      }

      return ref
          .watch(publishedStatsProvider(uid))
          .whenData(statsFromSnapshot);
    },
  );
});

/// The raw published document for [uid]. Prefer [profileStatsProvider], which
/// applies the privacy gate; this is the unguarded read beneath it.
final publishedStatsProvider =
    StreamProvider.family<ProfileStatsSnapshot, String>((ref, uid) {
  return ref.watch(profileStatsRepositoryProvider).watch(uid);
});
