import 'package:cloud_firestore/cloud_firestore.dart';

/// The `plannerAccess/{plannerUid}_{targetUid}` groupId HINT.
///
/// **The row is not the permission — the live grant is.** A read of
/// `scheduleItems/{targetUid}/items` carries no groupId, so the planner leaves a
/// row naming a group they hold a grant in; the schedule-read rule re-verifies
/// `callerHasActiveGrant(targetUid, groupId)` on every read. The row is only a
/// hint that tells the rule which group to check.
///
/// **The PLANNER writes their own row** (off the grants THEY hold —
/// `PlannerAccessReconciler`), which is what removes the old dependency on the
/// target being online to provision access. It is safe because the planner
/// cannot fabricate a grant: a self-written row with no matching live grant is
/// inert, and a row that outlives a revocation fails the read the moment the
/// grant is gone. See DECISIONS.md "Live-checked planner schedule access".
///
/// Friendship-scoped grants (later) carry no group and authorize reads directly
/// via a computed pair id, so they get NO row here — this is the group path only.
class PlannerAccessRepository {
  PlannerAccessRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _access =>
      _db.collection('plannerAccess');

  /// Must match `firestore.rules`' `accessId` construction exactly — the two
  /// compute the same id and have to stay in step.
  static String accessId(String plannerUid, String targetUid) =>
      '${plannerUid}_$targetUid';

  /// Write (or refresh) the caller's hint row for [targetUid], naming a group
  /// [groupId] in which the caller currently holds an active grant. The rules
  /// reject any group the caller isn't actually granted in, so a wrong or stale
  /// [groupId] simply fails rather than granting anything.
  Future<void> grant({
    required String plannerUid,
    required String targetUid,
    required String groupId,
  }) {
    return _access.doc(accessId(plannerUid, targetUid)).set({
      'plannerUid': plannerUid,
      'targetUid': targetUid,
      'groupId': groupId,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> revoke({
    required String plannerUid,
    required String targetUid,
  }) {
    return _access.doc(accessId(plannerUid, targetUid)).delete();
  }

  /// Every target the given planner currently has a hint row for.
  ///
  /// A query (not `get()`s) so the reconciler can notice rows it should DELETE —
  /// targets whose grant is gone. Needs the scoped `list` rule (plannerUid == me).
  Future<Set<String>> targetsFor(String plannerUid) async {
    final snap =
        await _access.where('plannerUid', isEqualTo: plannerUid).get();
    return {
      for (final doc in snap.docs) (doc.data()['targetUid'] ?? '') as String,
    }..remove('');
  }
}
