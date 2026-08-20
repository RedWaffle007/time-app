import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/group.dart';
import '../domain/membership.dart';
import '../domain/planner_grant.dart';

/// Groups, membership, invite codes, and planner-consent grants.
class GroupRepository {
  GroupRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _groups =>
      _db.collection('groups');

  /// Invite-code → groupId lookup (`joinCodes/{CODE}`). Exists so joining needs
  /// no read on the group doc, which is what lets `groups` be members-only:
  /// resolving a code by querying `groups` also allowed listing every group and
  /// every invite code. See firestore.rules.
  CollectionReference<Map<String, dynamic>> get _joinCodes =>
      _db.collection('joinCodes');

  // --- Groups & membership ---

  /// Groups the given user belongs to (via the denormalized memberUids array).
  Stream<List<Group>> watchMyGroups(String uid) {
    return _groups
        .where('memberUids', arrayContains: uid)
        .snapshots()
        .map((s) => s.docs.map(Group.fromDoc).toList());
  }

  Stream<List<Membership>> watchMembers(String groupId) {
    return _groups
        .doc(groupId)
        .collection('members')
        .snapshots()
        .map((s) => s.docs.map(Membership.fromDoc).toList());
  }

  /// Create a group; the creator becomes owner + first member.
  Future<Group> createGroup({
    required String name,
    required String ownerUid,
    required String ownerName,
  }) async {
    final code = _generateJoinCode();
    final ref = _groups.doc();
    await ref.set({
      'name': name.trim(),
      'ownerUid': ownerUid,
      'joinCode': code,
      'memberUids': [ownerUid],
      'createdAt': FieldValue.serverTimestamp(),
    });
    await ref.collection('members').doc(ownerUid).set({
      'name': ownerName,
      'joinedAt': FieldValue.serverTimestamp(),
    });
    // Register the code so joinByCode can resolve it without reading `groups`.
    // Written AFTER the group doc because the rule checks the caller owns that
    // group. Rules deny update/delete here, so a code collision (~1 in 10^9,
    // since _generateJoinCode doesn't check) now fails loudly at creation
    // instead of silently sending a joiner to whichever group came back first.
    await _joinCodes.doc(code).set({'groupId': ref.id});
    return Group(
      id: ref.id,
      name: name.trim(),
      ownerUid: ownerUid,
      joinCode: code,
      memberUids: [ownerUid],
    );
  }

  /// Join a group by its invite code. Returns the group, or null if no group
  /// has that code.
  ///
  /// Resolves the code through `joinCodes/{CODE}` rather than by querying
  /// `groups` — the group doc is readable by members only, and the caller isn't
  /// one yet. The self-join update deliberately needs no read permission, which
  /// is what makes this order work.
  Future<Group?> joinByCode({
    required String code,
    required String uid,
    required String name,
  }) async {
    final lookup = await _joinCodes.doc(code.trim().toUpperCase()).get();
    final groupId = lookup.data()?['groupId'] as String?;
    if (groupId == null || groupId.isEmpty) return null;

    final ref = _groups.doc(groupId);
    await ref.update({
      'memberUids': FieldValue.arrayUnion([uid]),
    });
    await ref.collection('members').doc(uid).set({
      'name': name,
      'joinedAt': FieldValue.serverTimestamp(),
    });
    // Re-read AFTER joining: the caller is a member now, so the group doc is
    // readable — and this snapshot has their own uid in memberUids. The old code
    // returned the pre-join snapshot, whose memberUids was already stale.
    final joined = await ref.get();
    return joined.exists ? Group.fromDoc(joined) : null;
  }

  // --- Planner consent grants ---

  Stream<List<PlannerGrant>> watchGrants(String groupId) {
    return _groups
        .doc(groupId)
        .collection('plannerGrants')
        .snapshots()
        .map((s) => s.docs.map(PlannerGrant.fromDoc).toList());
  }

  /// Every target the given planner may currently plan for, across all groups.
  /// Powers the schedule-builder's target picker.
  Stream<List<PlannerGrant>> watchTargetsFor(String plannerUid) {
    return _db
        .collectionGroup('plannerGrants')
        .where('plannerUid', isEqualTo: plannerUid)
        .where('granted', isEqualTo: true)
        .snapshots()
        .map((s) => s.docs.map(PlannerGrant.fromDoc).toList());
  }

  /// Target grants (or revokes) a planner permission over themselves. Caller
  /// must be the target — consent is the target's to give.
  Future<void> setPlannerGrant({
    required String groupId,
    required String plannerUid,
    required String targetUid,
    required bool granted,
  }) async {
    final id = PlannerGrant.docId(plannerUid, targetUid);
    await _groups.doc(groupId).collection('plannerGrants').doc(id).set({
      'plannerUid': plannerUid,
      'targetUid': targetUid,
      'groupId': groupId,
      'granted': granted,
      'grantedByUid': targetUid,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Give up a planner grant the SIGNED-IN user *holds* over someone — the
  /// "stop planning for them" direction.
  ///
  /// Deliberately NOT a call into [setPlannerGrant]. That one is the target's
  /// consent switch and can turn a grant on; this can only ever turn one off,
  /// and it is called by the planner, who must never be able to do the former.
  /// The rules enforce the same asymmetry, so collapsing the two here would
  /// produce a method whose happy path is denied half the time it is used.
  ///
  /// `update`, not `set(merge:)`: the rule's planner branch requires the write
  /// to touch only `granted` and `updatedAt`, and an update on a missing doc
  /// fails loudly rather than conjuring a grant no one consented to.
  Future<void> revokeMyPlannerGrant({
    required String groupId,
    required String plannerUid,
    required String targetUid,
  }) {
    final id = PlannerGrant.docId(plannerUid, targetUid);
    return _groups.doc(groupId).collection('plannerGrants').doc(id).update({
      'granted': false,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Remove [memberUid] from [groupId] — either the caller leaving (when
  /// [memberUid] is their own uid) or the owner ejecting someone.
  ///
  /// **The order is load-bearing and the rules enforce it.** Grants are revoked
  /// and the roster doc deleted FIRST, while the caller is still inside
  /// `memberUids` — `callerInGroup()` gates both writes, so dropping the array
  /// entry first would lock the caller out of the very cleanup they are doing.
  /// It is the exact inverse of [joinByCode], which writes `memberUids` before
  /// the member doc.
  ///
  /// Not a transaction, and deliberately so: these are three documents under
  /// three different rules, so an atomic removal is not on offer. `memberUids`
  /// is the single source of truth for membership and it moves last, so a
  /// failure part-way leaves only inert residue — a revoked grant or an
  /// orphaned roster doc — and re-running this cleans it up.
  Future<void> removeMember({
    required String groupId,
    required String memberUid,
    required String callerUid,
  }) async {
    // 1. Revoke live grants that the departing member is party to AND that the
    //    caller has standing to revoke (target, or planner giving one up). A
    //    left-behind `granted: true` would keep the person listed in the
    //    planner's target picker — watchTargetsFor filters on exactly that —
    //    long after they stopped sharing a group.
    //
    //    Grants between the departing member and a THIRD party are left alone:
    //    the caller is neither side of that consent and the rules refuse it.
    //    They are inert, because creating an item additionally requires the
    //    planner to still be in the group.
    final grants =
        await _groups.doc(groupId).collection('plannerGrants').get();
    for (final doc in grants.docs) {
      final d = doc.data();
      final planner = d['plannerUid'] as String?;
      final target = d['targetUid'] as String?;
      if (d['granted'] != true) continue;
      final involvesDeparting = planner == memberUid || target == memberUid;
      final callerIsParty = planner == callerUid || target == callerUid;
      if (involvesDeparting && callerIsParty) {
        await doc.reference.update({
          'granted': false,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    }

    // 2. The roster doc, while callerInGroup() still holds.
    await _groups.doc(groupId).collection('members').doc(memberUid).delete();

    // 3. Membership itself, last — it is what every rule above reads.
    await _groups.doc(groupId).update({
      'memberUids': FieldValue.arrayRemove([memberUid]),
    });
  }

  // --- helpers ---

  static const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no O/0/I/1
  String _generateJoinCode() {
    final rand = Random();
    return List.generate(
      6,
      (_) => _codeAlphabet[rand.nextInt(_codeAlphabet.length)],
    ).join();
  }
}
