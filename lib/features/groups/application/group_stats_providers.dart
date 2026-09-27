import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../social/application/stats_providers.dart';
import '../data/group_stats_repository.dart';
import '../domain/group_member_stat.dart';
import 'group_board.dart';
import 'group_providers.dart';

final groupStatsRepositoryProvider = Provider<GroupStatsRepository>((ref) {
  return GroupStatsRepository(FirebaseFirestore.instance);
});

/// Publishes the signed-in member's GROUP-SCOPED summary into every group
/// they belong to (item 24d): each group gets numbers over only the plans
/// tagged with it ([groupScopedStat]).
///
/// **Driven off the item stream, never off transitions** — the exact doctrine
/// of [ProfileStatsPublisher]. One recomputation per emission; there is no
/// per-transition hook. Idempotent via a per-group signature so an unchanged
/// recomputation (or a stream re-emit) writes nothing.
class GroupStatsPublisher {
  GroupStatsPublisher(this._ref);

  final Ref _ref;
  final Map<String, String> _lastSignatures = {};

  Future<void> publishIfChanged() async {
    final uid = _ref.read(currentUidProvider);
    if (uid == null) return;
    final items = _ref.read(allItemsAsTargetProvider).value;
    final profile = _ref.read(profileProvider).value;
    final groups = _ref.read(myGroupsProvider).value;
    if (items == null || profile == null || groups == null) return;

    final statItems = items.map(toStatItem).toList();
    final repo = _ref.read(groupStatsRepositoryProvider);
    for (final group in groups) {
      final stat = groupScopedStat(
        uid: uid,
        name: profile.name,
        groupId: group.id,
        itemsAsTarget: statItems,
        timezone: profile.homeTimezone,
      );
      // Skip when nothing a fellow member would see has changed. Firestore
      // re-emits on every local write, so without this a single completed
      // task would republish to every group repeatedly.
      final signature =
          '${stat.name}|${stat.tasksCompleted}|${stat.answered}|'
          '${stat.currentStreak}|${stat.bestStreak}';
      if (_lastSignatures[group.id] == signature) continue;
      try {
        await repo.publish(groupId: group.id, stat: stat);
        _lastSignatures[group.id] = signature;
      } catch (_) {
        // Best-effort, like every other publisher: a failure leaves a fellow
        // member's view stale, never my own record wrong. The signature stays
        // unset so the next emission retries.
      }
    }
  }

  /// Forget the signature on sign-out, so the next account's first publish is
  /// not skipped as "unchanged" against the previous account's numbers.
  void reset() => _lastSignatures.clear();
}

final groupStatsPublisherProvider = Provider<GroupStatsPublisher>((ref) {
  return GroupStatsPublisher(ref);
});

/// Every member's published summary for [groupId], live.
final groupMemberStatsProvider =
    StreamProvider.family<List<GroupMemberStat>, String>((ref, groupId) {
      return ref.watch(groupStatsRepositoryProvider).watch(groupId);
    });
