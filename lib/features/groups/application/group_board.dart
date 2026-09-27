import '../../social/application/streak_policy.dart';
import '../../social/domain/profile_stat.dart';
import '../domain/group_member_stat.dart';

/// **Group progress, pure** (item 24d, DECISIONS.md "24d — group progress").
/// No Firestore, no clock — `test/group_board_test.dart` drives it.

/// What one member publishes into [groupId]: their numbers over ONLY the plans
/// tagged with that group (cancelled plans excluded), humane streak included.
/// Group plans still count toward the member's own profile too — that is the
/// registry's job, over the whole record.
GroupMemberStat groupScopedStat({
  required String uid,
  required String name,
  required String groupId,
  required List<StatItem> itemsAsTarget,
  required String timezone,
}) {
  final mine = itemsAsTarget
      .where((i) => i.groupId == groupId && !i.isCancelled)
      .toList();
  final streaks = computeStreaks(mine, timezone);
  return GroupMemberStat(
    uid: uid,
    name: name,
    tasksCompleted: mine.where((i) => i.isDone).length,
    answered: mine.where((i) => i.hasOutcome).length,
    currentStreak: streaks.current,
    bestStreak: streaks.best,
  );
}

/// The board as the screen renders it.
class GroupBoard {
  const GroupBoard({
    required this.ranked,
    required this.unranked,
    required this.keptStreak,
    required this.memberCount,
    required this.followThrough,
  });

  /// Members with at least [kMinStatSample] answered group plans, best first.
  final List<GroupMemberStat> ranked;

  /// Everyone else, by name — listed, never ranked at the bottom as "0%".
  final List<GroupMemberStat> unranked;

  /// How many members currently have a streak going ("3 of 4 kept it going").
  final int keptStreak;

  /// Members on the board.
  final int memberCount;

  /// Pooled: all done ÷ all answered — null below [kMinStatSample] answered.
  final int? followThrough;

  bool get isEmpty => ranked.isEmpty && unranked.isEmpty;

  /// Nobody has answered a group plan yet.
  bool get hasNoAnswers =>
      [...ranked, ...unranked].every((s) => s.answered == 0);
}

/// Build the board from every published row, keeping only CURRENT members
/// ([memberUids]) — a row left behind by someone who left is never shown.
GroupBoard buildGroupBoard(
  List<GroupMemberStat> rows,
  List<String> memberUids,
) {
  final members = memberUids.toSet();
  final current = rows.where((r) => members.contains(r.uid)).toList();

  int byName(GroupMemberStat a, GroupMemberStat b) {
    final n = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return n != 0 ? n : a.uid.compareTo(b.uid);
  }

  final ranked = current.where((r) => r.followThrough != null).toList()
    ..sort((a, b) {
      final byFt = b.followThrough!.compareTo(a.followThrough!);
      if (byFt != 0) return byFt;
      final byDone = b.tasksCompleted.compareTo(a.tasksCompleted);
      if (byDone != 0) return byDone;
      return byName(a, b);
    });
  final unranked = current.where((r) => r.followThrough == null).toList()
    ..sort(byName);

  final done = current.fold<int>(0, (s, r) => s + r.tasksCompleted);
  final answered = current.fold<int>(0, (s, r) => s + r.answered);

  return GroupBoard(
    ranked: ranked,
    unranked: unranked,
    keptStreak: current.where((r) => r.currentStreak > 0).length,
    memberCount: current.length,
    followThrough: answered < kMinStatSample
        ? null
        : ((done / answered) * 100).round(),
  );
}
