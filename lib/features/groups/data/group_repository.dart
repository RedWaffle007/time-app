import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../social/domain/avatar.dart';
import '../domain/group.dart';
import '../domain/group_join_request.dart';
import '../domain/membership.dart';

/// Groups, membership, admins, invite codes and join requests.
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

  /// Stores picture metadata after the owner-authorized upload has completed.
  Future<void> setAvatar({
    required String groupId,
    required ProfileAvatar avatar,
  }) {
    return _groups.doc(groupId).update({'avatar': avatar.toMap()});
  }

  /// Clears the visible metadata before best-effort object deletion.
  Future<void> clearAvatar(String groupId) {
    return _groups.doc(groupId).update({'avatar': FieldValue.delete()});
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
      'adminUids': [ownerUid],
      'lastAdmittedUid': ownerUid,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await ref.collection('members').doc(ownerUid).set({
      'name': ownerName,
      'joinedAt': FieldValue.serverTimestamp(),
    });
    // Register the code so a candidate can request admission without reading
    // the members-only group document.
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
      adminUids: [ownerUid],
      lastAdmittedUid: ownerUid,
    );
  }

  /// Ask to join using a code. Knowing a code never changes membership: it only
  /// creates a pending request that any one admin decides (item 3). The caller
  /// then asks the Worker to push the admins (`groupJoinRequested`).
  ///
  /// Returns the group id, or null when the code does not exist. A candidate
  /// cannot read the group itself yet, so the public `joinCodes` lookup remains
  /// the only fact disclosed here.
  Future<String?> requestJoinByCode({
    required String code,
    required String uid,
    required String name,
  }) async {
    final normalizedCode = code.trim().toUpperCase();
    final lookup = await _joinCodes.doc(normalizedCode).get();
    final groupId = lookup.data()?['groupId'] as String?;
    if (groupId == null || groupId.isEmpty) return null;

    await _groups.doc(groupId).collection('joinRequests').doc(uid).set({
      'candidateUid': uid,
      'candidateName': name,
      'requestedByUid': uid,
      'source': 'code',
      'inviteCode': normalizedCode,
      'status': 'pending',
      'requiredApproverUids': <String>[],
      'approvalUids': <String>[],
      'rejectionUid': null,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return groupId;
  }

  /// Add or invite a friend (item 3, WhatsApp-style).
  ///
  /// An ADMIN's add is immediate: an approved `admin` request, the group array
  /// and the roster row commit in one batch, and this returns true. A
  /// non-admin's is only a pending `friend` request for the admins to decide;
  /// this returns false and the caller pushes the admins
  /// (`groupJoinRequested`). The rules enforce both, and that the candidate is
  /// the caller's friend.
  Future<bool> inviteFriend({
    required String groupId,
    required String callerUid,
    required String friendUid,
    required String friendName,
    required bool callerIsAdmin,
  }) async {
    final groupRef = _groups.doc(groupId);
    final requestRef = groupRef.collection('joinRequests').doc(friendUid);
    final request = <String, dynamic>{
      'candidateUid': friendUid,
      'candidateName': friendName,
      'requestedByUid': callerUid,
      'source': callerIsAdmin ? 'admin' : 'friend',
      'inviteCode': null,
      'status': callerIsAdmin ? 'approved' : 'pending',
      'requiredApproverUids': <String>[],
      'approvalUids': callerIsAdmin ? [callerUid] : <String>[],
      'rejectionUid': null,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (!callerIsAdmin) {
      await requestRef.set(request);
      return false;
    }
    final batch = _db.batch()
      ..set(requestRef, request)
      ..update(groupRef, {
        'memberUids': FieldValue.arrayUnion([friendUid]),
        'lastAdmittedUid': friendUid,
      })
      ..set(groupRef.collection('members').doc(friendUid), {
        'name': friendName,
        'joinedAt': FieldValue.serverTimestamp(),
      });
    await batch.commit();
    return true;
  }

  Stream<List<GroupJoinRequest>> watchJoinRequests(String groupId) {
    return _groups
        .doc(groupId)
        .collection('joinRequests')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(GroupJoinRequest.fromDoc)
              .where((request) => request.isPending)
              .toList(),
        );
  }

  /// An ADMIN decides a pending request (item 3: one admin is enough).
  /// Approving moves the request, the group array and the roster row together
  /// atomically — there is no partially joined state — and returns true (the
  /// caller then tells the candidate; the Worker re-verifies and dedups).
  /// Rejecting is terminal and returns false.
  Future<bool> decideJoinRequest({
    required String groupId,
    required String candidateUid,
    required String callerUid,
    required bool approve,
  }) async {
    final groupRef = _groups.doc(groupId);
    final requestRef = groupRef.collection('joinRequests').doc(candidateUid);
    final memberRef = groupRef.collection('members').doc(candidateUid);

    return _db.runTransaction<bool>((transaction) async {
      final requestSnapshot = await transaction.get(requestRef);
      final requestData = requestSnapshot.data();
      if (requestData == null) {
        throw StateError('Group join request no longer exists.');
      }
      if (requestData['status'] != 'pending') {
        throw StateError('Group join request has already been decided.');
      }

      if (!approve) {
        transaction.update(requestRef, {
          'status': 'rejected',
          'rejectionUid': callerUid,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return false;
      }

      transaction
        ..update(requestRef, {
          'requiredApproverUids': <String>[],
          'approvalUids': [callerUid],
          'status': 'approved',
          'updatedAt': FieldValue.serverTimestamp(),
        })
        ..update(groupRef, {
          'memberUids': FieldValue.arrayUnion([candidateUid]),
          'lastAdmittedUid': candidateUid,
        })
        ..set(memberRef, {
          'name': requestData['candidateName'],
          'joinedAt': FieldValue.serverTimestamp(),
        });
      return true;
    });
  }

  /// The creator makes a member an admin, or takes it away (item 3). Only the
  /// creator may — the rules refuse anyone else, including other admins.
  Future<void> setAdmin({
    required String groupId,
    required String memberUid,
    required bool admin,
  }) {
    return _groups.doc(groupId).update({
      'adminUids': admin
          ? FieldValue.arrayUnion([memberUid])
          : FieldValue.arrayRemove([memberUid]),
    });
  }

  /// Remove [memberUid] from [groupId] — the caller leaving (their own uid)
  /// or an admin removing someone (item 3). Never the creator.
  ///
  /// **The order is load-bearing and the rules enforce it.** The roster doc is
  /// deleted FIRST, while the caller is still inside `memberUids` —
  /// `callerInGroup()` gates that delete, so dropping the array entry first
  /// would lock a leaving member out of their own cleanup. `memberUids` is the
  /// source of truth and moves last, together with the person's admin entry
  /// (a removed admin is no longer an admin); a failure part-way leaves only an
  /// orphaned roster row, and re-running cleans it up.
  Future<void> removeMember({
    required String groupId,
    required String memberUid,
    required String callerUid,
  }) async {
    // Their group stats go first (item 24d), while an admin caller is still
    // provably an admin and the leaver still a member — best-effort: a row
    // left behind is filtered off the board by `memberUids` anyway.
    try {
      await _groups
          .doc(groupId)
          .collection('memberStats')
          .doc(memberUid)
          .delete();
    } catch (_) {}
    await _groups.doc(groupId).collection('members').doc(memberUid).delete();
    await _groups.doc(groupId).update({
      'memberUids': FieldValue.arrayRemove([memberUid]),
      'adminUids': FieldValue.arrayRemove([memberUid]),
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
