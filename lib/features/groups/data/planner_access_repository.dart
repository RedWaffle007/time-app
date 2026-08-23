import 'package:cloud_firestore/cloud_firestore.dart';

/// The `plannerAccess/{plannerUid}_{targetUid}` mirror.
///
/// **Existence is the permission.** It answers the one question a Firestore rule
/// cannot: "does this planner hold at least one active grant over this target,
/// in *any* group?" `callerHasActiveGrant()` needs a groupId, and a read of
/// `scheduleItems/{targetUid}/items` carries none — rules can construct a path
/// and cannot run a query. So the answer is precomputed into a path.
///
/// **Only the target writes here.** A planner able to mint their own row could
/// read any schedule in the project; the rules pin `targetUid` to the caller.
///
/// It is a DENORMALIZATION of `plannerGrants`, kept in step by
/// `PlannerAccessReconciler` off the grant stream — never by the grant
/// transitions. See that class.
class PlannerAccessRepository {
  PlannerAccessRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _access =>
      _db.collection('plannerAccess');

  /// Must match `firestore.rules`' `accessId` construction exactly. The two
  /// compute the same id and have to stay in step — the same contract
  /// `social_ids.dart` documents for the friend graph.
  static String accessId(String plannerUid, String targetUid) =>
      '${plannerUid}_$targetUid';

  Future<void> grant({
    required String plannerUid,
    required String targetUid,
  }) {
    return _access.doc(accessId(plannerUid, targetUid)).set({
      'plannerUid': plannerUid,
      'targetUid': targetUid,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> revoke({
    required String plannerUid,
    required String targetUid,
  }) {
    return _access.doc(accessId(plannerUid, targetUid)).delete();
  }

  /// Every planner currently mirrored for [targetUid].
  ///
  /// A query rather than a set of `get()`s, because the reconciler has to notice
  /// rows it should DELETE — ones no grant justifies any more. It cannot see
  /// those by looking only at the grants.
  Future<Set<String>> plannersFor(String targetUid) async {
    final snap =
        await _access.where('targetUid', isEqualTo: targetUid).get();
    return {
      for (final doc in snap.docs) (doc.data()['plannerUid'] ?? '') as String,
    }..remove('');
  }
}
