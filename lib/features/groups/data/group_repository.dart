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
