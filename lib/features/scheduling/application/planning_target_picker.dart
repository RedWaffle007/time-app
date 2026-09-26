import '../../groups/domain/planner_grant.dart';

/// Whether the group-detail permission control belongs beside this member.
/// Friends need no permission at all (friendship is the permission).
bool groupPlanningPermissionApplies(
  String memberUid, {
  required Set<String> friendUids,
}) => !friendUids.contains(memberUid);

/// Everyone [plannerUid] may plan for right now, one row per person.
///
/// Batch G item 2 (2026-09-27, DECISIONS.md "Friendship is the planning
/// permission"): every FRIEND is a target, with no grant — their row is
/// synthesised with an empty `groupId` (a friendship plan). A GROUP grant still
/// counts for someone who is not a friend (until groups are reworked). Leftover
/// friendship grant documents (`groupId == ''`) are ignored either way: they
/// neither add a non-friend nor remove a friend.
List<PlannerGrant> effectivePlanningTargets(
  Iterable<PlannerGrant> grants, {
  required Set<String> friendUids,
  required String plannerUid,
}) {
  final byTarget = <String, PlannerGrant>{
    for (final friend in friendUids)
      if (friend.isNotEmpty && friend != plannerUid)
        friend: PlannerGrant(
          plannerUid: plannerUid,
          targetUid: friend,
          groupId: '',
          granted: true,
        ),
  };
  for (final grant in grants) {
    if (!grant.granted || grant.targetUid.isEmpty) continue;
    if (grant.groupId.isEmpty) continue;
    if (friendUids.contains(grant.targetUid)) continue;
    byTarget.putIfAbsent(grant.targetUid, () => grant);
  }
  return byTarget.values.toList(growable: false);
}
