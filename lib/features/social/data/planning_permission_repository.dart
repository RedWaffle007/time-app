import 'package:cloud_firestore/cloud_firestore.dart';

import '../../groups/domain/planner_grant.dart';
import '../domain/planning_request.dart';
import '../domain/social_ids.dart';
import 'relation_stream.dart';

/// Friendship-scoped planning permission: the target-controlled grant that lets
/// a friend plan for them, plus the request flow for asking.
///
/// **The friendship still grants nothing by itself** (DECISIONS.md
/// "Friendship-scoped planning grants"). Permission is a separate,
/// per-direction, target-controlled grant at
/// `friendships/{sortedPair}/plannerGrants/{plannerUid}_{targetUid}` — the SAME
/// path the group grants live under a group, so the planner's collection-group
/// target picker (`watchTargetsFor`) picks it up with no change. Consent is the
/// target's: only they write `granted: true`.
///
/// This handles the [PlanningKind.normal] grant (the plannerGrants subtree).
/// The emergency grant (#5) is a separate subtree and lands here later.
class PlanningPermissionRepository {
  PlanningPermissionRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _requests =>
      _db.collection('planningRequests');

  /// The grant subcollection for a [kind]: `plannerGrants` (normal) or
  /// `emergencyGrants` (emergency). Two SEPARATE, independent grants — the rules
  /// enforce that neither implies the other (DECISIONS.md "Emergency item tier").
  String _grantCollection(PlanningKind kind) =>
      kind == PlanningKind.emergency ? 'emergencyGrants' : 'plannerGrants';

  /// The friendship grant doc for `planner` may-plan-for `target`, of [kind].
  DocumentReference<Map<String, dynamic>> _grantDoc(
    String plannerUid,
    String targetUid,
    PlanningKind kind,
  ) =>
      _db
          .collection('friendships')
          .doc(friendshipId(plannerUid, targetUid))
          .collection(_grantCollection(kind))
          .doc('${plannerUid}_$targetUid');

  // --- the grant (target-controlled) ---

  /// The TARGET sets whether [plannerUid] may plan for them, of [kind]. Caller
  /// must be [targetUid] — consent is the target's. `groupId` is ''
  /// (friendship-scoped) and `grantedByUid` is the target, matching the rules.
  Future<void> setGrant({
    required String plannerUid,
    required String targetUid,
    required bool granted,
    PlanningKind kind = PlanningKind.normal,
  }) {
    return _grantDoc(plannerUid, targetUid, kind).set({
      'plannerUid': plannerUid,
      'targetUid': targetUid,
      'groupId': '',
      'granted': granted,
      'grantedByUid': targetUid,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // --- emergency grants: collection-group queries (own indexes) ---

  /// Targets the signed-in [plannerUid] may EMERGENCY-plan for. Mirrors
  /// `watchTargetsFor` for the emergency subtree; returned as [PlannerGrant]
  /// (same field shape). Powers the builder's emergency-tier availability.
  Stream<List<PlannerGrant>> watchEmergencyTargetsFor(String plannerUid) {
    return _db
        .collectionGroup('emergencyGrants')
        .where('plannerUid', isEqualTo: plannerUid)
        .where('granted', isEqualTo: true)
        .snapshots()
        .map((s) => s.docs.map(PlannerGrant.fromDoc).toList());
  }

  /// Emergency grants OTHER people hold over [targetUid] — who may
  /// emergency-plan for me. Not filtered to `granted` (a toggle needs the false
  /// state too), like `watchGrantsOverTarget`.
  Stream<List<PlannerGrant>> watchEmergencyGrantsOverTarget(String targetUid) {
    return _db
        .collectionGroup('emergencyGrants')
        .where('targetUid', isEqualTo: targetUid)
        .snapshots()
        .map((s) => s.docs.map(PlannerGrant.fromDoc).toList());
  }

  // --- the request flow ---

  /// [fromUid] asks [toUid] for permission to plan for them.
  ///
  /// A `set` on the deterministic id. Settled requests are deleted, so normally
  /// this is a clean create; a stale row is self-healed the way
  /// `FriendRepository.sendRequest` does it.
  Future<void> sendRequest({
    required String fromUid,
    required String toUid,
    PlanningKind kind = PlanningKind.normal,
  }) async {
    final id =
        PlanningRequest.requestId(fromUid: fromUid, toUid: toUid, kind: kind);
    final ref = _requests.doc(id);
    final body = {
      'fromUid': fromUid,
      'toUid': toUid,
      'kind': kind.name,
      'participants': [fromUid, toUid],
      'status': PlanningRequestStatus.pending.name,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    try {
      await ref.set(body);
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      try {
        await ref.delete();
      } catch (_) {}
      await ref.set(body);
    }
  }

  /// The outgoing request from [fromUid] to [toUid] of [kind], live. Null when
  /// none is pending.
  Stream<PlanningRequest?> watchOutgoing({
    required String fromUid,
    required String toUid,
    PlanningKind kind = PlanningKind.normal,
  }) {
    final id =
        PlanningRequest.requestId(fromUid: fromUid, toUid: toUid, kind: kind);
    return relationStreamAbsentOnDenied<PlanningRequest?>(
      _requests.doc(id).snapshots(),
      (d) => d.exists ? PlanningRequest.fromDoc(d) : null,
      null,
    );
  }

  /// Planning requests the signed-in user has SENT and nobody has decided.
  ///
  /// A live, caller-scoped `fromUid == me` query — used to resolve a specific
  /// friend's outgoing-request state reactively, the way the friend graph
  /// derives its per-pair state from caller-scoped queries rather than a
  /// single-doc listener that terminates on the absence-denial.
  Stream<List<PlanningRequest>> watchOutgoingRequests(String uid) {
    return _requests
        .where('fromUid', isEqualTo: uid)
        .snapshots()
        .map((s) => s.docs
            .map(PlanningRequest.fromDoc)
            .where((r) => r.status == PlanningRequestStatus.pending)
            .toList());
  }

  /// Requests waiting on [uid] to decide — their planning-permission inbox.
  ///
  /// Filtered to `pending` in Dart (single-field `toUid` query, no composite
  /// index): settled requests are deleted, so in practice only pending rows are
  /// here, but the guard keeps a transient decided row out of the inbox.
  Stream<List<PlanningRequest>> watchIncoming(String uid) {
    return _requests
        .where('toUid', isEqualTo: uid)
        .snapshots()
        .map((s) => s.docs
            .map(PlanningRequest.fromDoc)
            .where((r) => r.status == PlanningRequestStatus.pending)
            .toList());
  }

  /// The recipient approves: write the grant (permission is the grant, not this
  /// row), THEN delete the request. Grant first so a failure part-way leaves the
  /// permission granted with a stale ask beside it — recoverable — rather than a
  /// cleared ask and no permission.
  Future<void> approve(PlanningRequest request) async {
    await setGrant(
      plannerUid: request.fromUid,
      targetUid: request.toUid,
      granted: true,
      kind: request.kind, // normal → plannerGrants, emergency → emergencyGrants
    );
    await _requests.doc(request.id).delete();
  }

  /// Decline (recipient) or withdraw (sender) — the row is deleted either way.
  Future<void> deleteRequest(PlanningRequest request) {
    return _requests.doc(request.id).delete();
  }
}
