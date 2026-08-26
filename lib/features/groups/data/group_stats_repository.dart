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

  /// Publish the signed-in member's summary into [groupId]. The field set
  /// matches the rules' whitelist exactly.
  Future<void> publish({
    required String groupId,
    required String uid,
    required String name,
    required int tasksCompleted,
    required int currentStreak,
    required double followThrough,
  }) {
    return _col(groupId).doc(uid).set({
      'name': name,
      'tasksCompleted': tasksCompleted,
      'currentStreak': currentStreak,
      'followThrough': followThrough,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Every member's published summary for [groupId], live.
  Stream<List<GroupMemberStat>> watch(String groupId) {
    return _col(groupId).snapshots().map(
          (s) => s.docs.map(GroupMemberStat.fromDoc).toList(),
        );
  }
}
