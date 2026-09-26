import '../../groups/domain/planner_grant.dart';

/// Everyone [plannerUid] may plan for individually right now: every FRIEND,
/// one row each (Batch G item 2 — friendship is the permission).
///
/// Group members who are not friends are deliberately absent: inside a group
/// you plan only for the whole group (item 3, "Plan for the group"), never for
/// one member. Rows are synthesised with an empty `groupId` (a friendship
/// plan); no grant document is read.
List<PlannerGrant> effectivePlanningTargets({
  required Set<String> friendUids,
  required String plannerUid,
}) {
  return [
    for (final friend in friendUids)
      if (friend.isNotEmpty && friend != plannerUid)
        PlannerGrant(
          plannerUid: plannerUid,
          targetUid: friend,
          groupId: '',
          granted: true,
        ),
  ];
}
