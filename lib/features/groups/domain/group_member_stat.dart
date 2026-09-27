import 'package:cloud_firestore/cloud_firestore.dart';

import '../../social/domain/profile_stat.dart';

/// One member's PUBLISHED accountability summary for ONE group, at
/// `groups/{groupId}/memberStats/{uid}`.
///
/// **Published, not derived** — a group member cannot read another member's
/// items nor their friend-gated `profileStats`, so each member's device writes
/// this small doc and fellow members read it. **Group-scoped** since item 24d:
/// every number counts only plans tagged with this group. The rules make it
/// self-write / member-read, admin-deletable, and require the 24d shape.
class GroupMemberStat {
  const GroupMemberStat({
    required this.uid,
    required this.name,
    required this.tasksCompleted,
    required this.answered,
    required this.currentStreak,
    required this.bestStreak,
  });

  final String uid;
  final String name;

  /// This group's plans the member completed.
  final int tasksCompleted;

  /// This group's plans the member answered (done + skipped + missed).
  final int answered;

  final int currentStreak;
  final int bestStreak;

  /// Done ÷ answered as a whole percent — null below [kMinStatSample], so a
  /// member with one answered plan is never "100%" or "0%" on the board.
  int? get followThrough => answered < kMinStatSample
      ? null
      : ((tasksCompleted / answered) * 100).round();

  /// A pre-24d row carries no `answered`; it reads as 0 answered (unranked)
  /// until that member's 24d build republishes.
  factory GroupMemberStat.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return GroupMemberStat(
      uid: doc.id,
      name: (d['name'] ?? '') as String,
      tasksCompleted: (d['tasksCompleted'] as num?)?.toInt() ?? 0,
      answered: (d['answered'] as num?)?.toInt() ?? 0,
      currentStreak: (d['currentStreak'] as num?)?.toInt() ?? 0,
      bestStreak: (d['bestStreak'] as num?)?.toInt() ?? 0,
    );
  }
}
