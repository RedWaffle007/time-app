import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/group_member_stat.dart';

/// Reads and writes `groups/{groupId}/memberStats/{uid}` — the group
/// accountability + leaderboard data. Each member publishes only their OWN row
/// (the rules enforce it); any member reads the whole collection.
class GroupStatsRepository {
  GroupStatsRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _col(String groupId) =>
      _db.collection('groups').doc(groupId).collection('memberStats');

  /// Publish the signed-in member's group-scoped summary into [groupId].
  ///
  /// A FULL replace, never a merge: the rules check the whole resulting
  /// document against the 24d shape, so merging over a pre-24d row would keep
  /// its retired `followThrough` field and be denied.
  Future<void> publish({
    required String groupId,
    required GroupMemberStat stat,
  }) {
    return _col(groupId).doc(stat.uid).set({
      'name': stat.name,
      'tasksCompleted': stat.tasksCompleted,
      'answered': stat.answered,
      'currentStreak': stat.currentStreak,
      'bestStreak': stat.bestStreak,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Remove [uid]'s row — on leave (self) or removal (an admin; item 24d).
  Future<void> delete({required String groupId, required String uid}) =>
      _col(groupId).doc(uid).delete();

  /// Every member's published summary for [groupId], live.
  Stream<List<GroupMemberStat>> watch(String groupId) {
    return _col(
      groupId,
    ).snapshots().map((s) => s.docs.map(GroupMemberStat.fromDoc).toList());
  }
}
