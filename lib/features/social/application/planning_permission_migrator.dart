import '../../groups/domain/planner_grant.dart';

/// A legacy active group grant that must move to the friendship/profile scope.
typedef GroupGrantMigration = ({
  String groupId,
  String plannerUid,
  String targetUid,
  bool friendshipGrantAlreadyExists,
});

/// Pure migration plan for item 13.
///
/// Once two users are friends, their profile grant is the sole authority. Each
/// active group grant over the signed-in target is therefore mirrored to the
/// friendship path (unless already present) and then revoked in its group.
List<GroupGrantMigration> groupGrantsToMigrate({
  required Iterable<PlannerGrant> grantsOverTarget,
  required Set<String> friendUids,
}) {
  final activeFriendPlanners = <String>{
    for (final grant in grantsOverTarget)
      if (grant.granted && grant.groupId.isEmpty) grant.plannerUid,
  };
  return [
    for (final grant in grantsOverTarget)
      if (grant.granted &&
          grant.groupId.isNotEmpty &&
          friendUids.contains(grant.plannerUid))
        (
          groupId: grant.groupId,
          plannerUid: grant.plannerUid,
          targetUid: grant.targetUid,
          friendshipGrantAlreadyExists: activeFriendPlanners.contains(
            grant.plannerUid,
          ),
        ),
  ];
}

class PlanningPermissionMigrator {
  bool _running = false;

  Future<void> migrate({
    required Iterable<PlannerGrant> grantsOverTarget,
    required Set<String> friendUids,
    required Future<void> Function(String plannerUid, String targetUid)
    ensureFriendshipGrant,
    required Future<void> Function(
      String groupId,
      String plannerUid,
      String targetUid,
    )
    revokeGroupGrant,
  }) async {
    if (_running) return;
    _running = true;
    try {
      final migrations = groupGrantsToMigrate(
        grantsOverTarget: grantsOverTarget,
        friendUids: friendUids,
      );
      for (final migration in migrations) {
        // Grant first, revoke second. A crash between them leaves duplicate
        // documents, but the group copy is already inert for friends and the
        // next pass safely finishes the cleanup.
        if (!migration.friendshipGrantAlreadyExists) {
          await ensureFriendshipGrant(
            migration.plannerUid,
            migration.targetUid,
          );
        }
        await revokeGroupGrant(
          migration.groupId,
          migration.plannerUid,
          migration.targetUid,
        );
      }
    } finally {
      _running = false;
    }
  }
}
