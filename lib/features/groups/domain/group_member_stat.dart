import 'package:cloud_firestore/cloud_firestore.dart';

/// One member's PUBLISHED accountability summary, at
/// `groups/{groupId}/memberStats/{uid}`.
///
/// **Published, not derived** — a group member cannot read another member's
/// items nor their friend-gated `profileStats`, so each member's device writes
/// this small doc and fellow members read it. Same doctrine as
/// `ProfileStatsRepository`. The values summarise the writer's OWN record; the
/// rules make it self-write / member-read.
class GroupMemberStat {
  const GroupMemberStat({
    required this.uid,
    required this.name,
    required this.tasksCompleted,
    required this.currentStreak,
    required this.followThrough,
  });

  final String uid;
  final String name;
  final int tasksCompleted;
  final int currentStreak;

  /// Follow-through as a percentage, 0–100.
  final double followThrough;

  factory GroupMemberStat.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return GroupMemberStat(
      uid: doc.id,
      name: (d['name'] ?? '') as String,
      tasksCompleted: (d['tasksCompleted'] as num?)?.toInt() ?? 0,
      currentStreak: (d['currentStreak'] as num?)?.toInt() ?? 0,
      followThrough: (d['followThrough'] as num?)?.toDouble() ?? 0,
    );
  }
}
