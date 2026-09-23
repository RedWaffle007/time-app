import '../../groups/domain/planner_grant.dart';

/// Whether the group-detail permission control belongs beside this member.
/// Friends manage the same consent on their profile instead.
bool groupPlanningPermissionApplies(
  String memberUid, {
  required Set<String> friendUids,
}) => !friendUids.contains(memberUid);

/// The currently effective targets after applying relationship scope.
///
/// A friendship grant is valid only while the pair are friends. A group grant
/// is valid only while they are not friends: once friendship exists, planning
/// consent lives permanently on the profile instead of having two independent
/// switches. One target row is returned even while old duplicate documents are
/// being migrated in the background.
List<PlannerGrant> effectivePlanningTargets(
  Iterable<PlannerGrant> grants, {
  required Set<String> friendUids,
}) {
  final byTarget = <String, PlannerGrant>{};
  for (final grant in grants) {
    if (!grant.granted || grant.targetUid.isEmpty) continue;
    final isFriend = friendUids.contains(grant.targetUid);
    final friendshipScoped = grant.groupId.isEmpty;
    if (isFriend != friendshipScoped) continue;
    final existing = byTarget[grant.targetUid];
    if (existing == null) {
      byTarget[grant.targetUid] = grant;
    }
  }
  return byTarget.values.toList(growable: false);
}
