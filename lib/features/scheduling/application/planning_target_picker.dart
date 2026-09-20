import '../../groups/domain/planner_grant.dart';

/// One target row per person, even when the planner holds grants through more
/// than one relationship (for example, a friendship and a shared group).
///
/// Prefer the direct friendship grant (`groupId == ''`) because it is the least
/// ambiguous authorization path for a friend plan. Otherwise preserve the
/// first live group grant returned by Firestore.
List<PlannerGrant> uniquePlanningTargets(Iterable<PlannerGrant> grants) {
  final byTarget = <String, PlannerGrant>{};
  for (final grant in grants) {
    if (!grant.granted || grant.targetUid.isEmpty) continue;
    final existing = byTarget[grant.targetUid];
    if (existing == null ||
        (existing.groupId.isNotEmpty && grant.groupId.isEmpty)) {
      byTarget[grant.targetUid] = grant;
    }
  }
  return byTarget.values.toList(growable: false);
}
