import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../social/application/stats_providers.dart';
import '../data/group_stats_repository.dart';
import '../domain/group_member_stat.dart';
import 'group_providers.dart';

final groupStatsRepositoryProvider = Provider<GroupStatsRepository>((ref) {
  return GroupStatsRepository(FirebaseFirestore.instance);
});

/// Publishes the signed-in member's summary into every group they belong to, so
/// fellow members can render accountability + a leaderboard.
///
/// **Driven off the item stream, never off transitions** — the exact doctrine
/// of [ProfileStatsPublisher], and it reuses that same computation
/// ([myComputedStatsProvider]). One recomputation is written to each of my
/// groups; there is no per-transition hook. Idempotent via a signature so an
/// unchanged recomputation (or a stream re-emit) writes nothing.
class GroupStatsPublisher {
  GroupStatsPublisher(this._ref);

  final Ref _ref;
  String? _lastSignature;

  Future<void> publishIfChanged() async {
    final uid = _ref.read(currentUidProvider);
    if (uid == null) return;
    final values = _ref.read(myComputedStatsProvider).value;
    final name = _ref.read(profileProvider).value?.name;
    final groups = _ref.read(myGroupsProvider).value;
    if (values == null || name == null || groups == null) return;

    final tasksCompleted = (values['tasksCompleted'] ?? 0).toInt();
    final currentStreak = (values['currentStreak'] ?? 0).toInt();
    final followThrough = (values['followThrough'] ?? 0).toDouble();
    final groupIds = (groups.map((g) => g.id).toList()..sort());

    // Skip when nothing a fellow member would see has changed — same values,
    // same set of groups. Firestore re-emits on every local write, so without
    // this a single completed task would republish to every group repeatedly.
    final signature =
        '$name|$tasksCompleted|$currentStreak|$followThrough|${groupIds.join(',')}';
    if (signature == _lastSignature) return;

    final repo = _ref.read(groupStatsRepositoryProvider);
    var allOk = true;
    for (final groupId in groupIds) {
      try {
        await repo.publish(
          groupId: groupId,
          uid: uid,
          name: name,
          tasksCompleted: tasksCompleted,
          currentStreak: currentStreak,
          followThrough: followThrough,
        );
      } catch (_) {
        // Best-effort, like every other publisher: a failure leaves a fellow
        // member's view stale, never my own record wrong. Don't cache the
        // signature so the next emission retries.
        allOk = false;
      }
    }
    if (allOk) _lastSignature = signature;
  }

  /// Forget the signature on sign-out, so the next account's first publish is
  /// not skipped as "unchanged" against the previous account's numbers.
  void reset() => _lastSignature = null;
}

final groupStatsPublisherProvider = Provider<GroupStatsPublisher>((ref) {
  return GroupStatsPublisher(ref);
});

/// Every member's published summary for [groupId], live.
final groupMemberStatsProvider =
    StreamProvider.family<List<GroupMemberStat>, String>((ref, groupId) {
  return ref.watch(groupStatsRepositoryProvider).watch(groupId);
});
