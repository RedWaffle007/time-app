import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/friend_request.dart';
import '../domain/friendship.dart';
import '../domain/social_ids.dart';
import 'relation_stream.dart';

/// Friend requests and friendships.
///
/// **Two collections, deliberately, rather than one document with a status.**
/// A request and a friendship have different lifetimes, different readers and
/// different rules: a request is directed, decided once and kept as a record;
/// a friendship is symmetric, has no status at all, and is the thing every
/// privacy rule `exists()`-checks on the hot path. Collapsing them would put a
/// status field in the middle of the most-read predicate in the app, and every
/// rule would have to read a field instead of an address.
///
/// The write paths mirror `group_repository.dart`'s discipline: multi-document
/// changes are ordered so a failure part-way leaves inert residue rather than a
/// broken invariant, and each write is scoped to exactly the fields the rules
/// permit.
class FriendRepository {
  FriendRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _requests =>
      _db.collection('friendRequests');

  CollectionReference<Map<String, dynamic>> get _friendships =>
      _db.collection('friendships');

  // --- reads ---

  /// Everyone [uid] is friends with.
  ///
  /// Queries the denormalised `participants` array rather than two separate
  /// `uidA == me` / `uidB == me` queries whose results would have to be merged
  /// client-side. See [Friendship] on why that array carries no security
  /// weight: the rules read the document id, never this field.
  Stream<List<Friendship>> watchFriends(String uid) {
    return _friendships
        .where('participants', arrayContains: uid)
        .snapshots()
        .map((s) => s.docs.map(Friendship.fromDoc).toList());
  }

  /// Requests waiting on [uid] to decide — their inbox.
  ///
  /// Filtered to `pending` in the query, not in Dart: the rules permit reading
  /// a request only when you are a party to it, and a narrower query is also a
  /// smaller read. Rejected and cancelled rows stay in the collection (see
  /// [FriendRequestStatus]) and must not appear here.
  Stream<List<FriendRequest>> watchIncomingRequests(String uid) {
    return _requests
        .where('toUid', isEqualTo: uid)
        .where('status', isEqualTo: FriendRequestStatus.pending.name)
        .snapshots()
        .map((s) => s.docs.map(FriendRequest.fromDoc).toList());
  }

  /// Requests [uid] has sent and nobody has decided yet.
  Stream<List<FriendRequest>> watchOutgoingRequests(String uid) {
    return _requests
        .where('fromUid', isEqualTo: uid)
        .where('status', isEqualTo: FriendRequestStatus.pending.name)
        .snapshots()
        .map((s) => s.docs.map(FriendRequest.fromDoc).toList());
  }

  /// Whether two users are friends. A single `get` on a computed id — no query,
  /// which is what makes the same check cheap inside a security rule.
  Future<bool> areFriends(String uidA, String uidB) async {
    if (uidA == uidB) return false;
    final doc = await _friendships.doc(friendshipId(uidA, uidB)).get();
    return doc.exists;
  }

  /// Live version of [areFriends], for a profile screen that must react when
  /// the other party accepts while it is open.
  Stream<bool> watchFriendship(String uidA, String uidB) {
    if (uidA == uidB) return Stream.value(false);
    return relationStreamAbsentOnDenied<bool>(
      _friendships.doc(friendshipId(uidA, uidB)).snapshots(),
      (d) => d.exists,
      false,
    );
  }

  /// The request between two users in a given direction, live. Null when none
  /// exists or it is no longer pending.
  Stream<FriendRequest?> watchRequest({
    required String fromUid,
    required String toUid,
  }) {
    if (fromUid == toUid) return Stream.value(null);
    return relationStreamAbsentOnDenied<FriendRequest?>(
      _requests.doc(friendRequestId(fromUid: fromUid, toUid: toUid)).snapshots(),
      (d) => d.exists ? FriendRequest.fromDoc(d) : null,
      null,
    );
  }

  // --- writes ---

  /// Send a friend request from [fromUid] to [toUid].
  ///
  /// A `set` on a deterministic id, so sending twice never duplicates. Decline
  /// and withdraw now DELETE the request (see [rejectRequest] / [cancelRequest]
  /// and DECISIONS.md "Friend-request reactivity + lifecycle"), so the common
  /// re-add path is a clean create.
  ///
  /// **Self-healing on a leftover doc.** A settled request predating that change
  /// — an old `rejected`/`cancelled` row, or an `accepted` one whose friendship
  /// was later removed — would turn this `set` into an *update* the rules forbid
  /// (`permission-denied`). When that happens we delete the stale row and create
  /// fresh. If the real reason was a BLOCK, the retried create is denied again
  /// and that error surfaces — the block is still enforced.
  Future<void> sendRequest({
    required String fromUid,
    required String toUid,
  }) async {
    final id = friendRequestId(fromUid: fromUid, toUid: toUid);
    final ref = _requests.doc(id);
    final body = {
      'fromUid': fromUid,
      'toUid': toUid,
      // Both parties in one array so each side can list their own requests
      // without a second query. The rules check fromUid/toUid directly.
      'participants': [fromUid, toUid],
      'status': FriendRequestStatus.pending.name,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    try {
      await ref.set(body);
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      // A stale settled row is in the way. Clear it (ignored if it is absent or
      // the delete itself is refused) and create fresh; a genuine block still
      // fails the create below.
      try {
        await ref.delete();
      } catch (_) {}
      await ref.set(body);
    }
  }

  /// The recipient accepts. Creates the friendship and settles the request.
  ///
  /// **The friendship is written FIRST**, and the order is load-bearing in the
  /// same way `removeMember`'s is. The friendship document is the one every
  /// privacy rule reads; the request row is only a record of how it came about.
  /// Writing the friendship first means a failure part-way leaves a real
  /// friendship with a stale `pending` request beside it — visible, harmless,
  /// and fixed by tapping Accept again. The reverse order would leave an
  /// `accepted` request with no friendship: the UI would say they are friends
  /// while every rule disagreed, which is the one state with no recovery from
  /// the client.
  ///
  /// Not a transaction, deliberately: the two documents live under different
  /// rules with different predicates, so an atomic write is not on offer.
  Future<void> acceptRequest(FriendRequest request) async {
    final a = request.fromUid;
    final b = request.toUid;

    await _friendships.doc(friendshipId(a, b)).set({
      // Sorted, matching the id. Which uid is which carries no meaning — see
      // Friendship.uidA.
      'uidA': a.compareTo(b) < 0 ? a : b,
      'uidB': a.compareTo(b) < 0 ? b : a,
      'participants': [a, b],
      'createdAt': FieldValue.serverTimestamp(),
    });

    await _requests.doc(request.id).set({
      'status': FriendRequestStatus.accepted.name,
      'decidedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// The recipient declines — the request is DELETED, not flagged.
  ///
  /// Keeping a `rejected` row was the earlier design; it made re-adding
  /// impossible (the sender's next `sendRequest` collided with the stale doc and
  /// was denied) and it let a determined sender detect the decline. Deleting
  /// leaves the pair exactly as if no request had been sent: re-requestable, and
  /// the decline is not announced. Spam is throttled by blocking, not by a
  /// permanent "no". See DECISIONS.md "Friend-request reactivity + lifecycle".
  Future<void> rejectRequest(FriendRequest request) {
    return _requests.doc(request.id).delete();
  }

  /// The sender withdraws a pending request (or either party clears one) — also
  /// a DELETE, for the same reasons as [rejectRequest]. A withdrawn request that
  /// lingered would block the sender from ever re-adding.
  Future<void> cancelRequest(FriendRequest request) {
    return _requests.doc(request.id).delete();
  }

  /// End a friendship. Either party may, and neither is notified.
  ///
  /// Deleting the document rather than flagging it: a friendship has no status
  /// and never did, and an `active: false` row would be a second thing every
  /// privacy rule had to read.
  ///
  /// The leftover `accepted` request row is ALSO cleared (best-effort, both
  /// directions), so the overflow's promise — "either of you can send a new
  /// request later" — is actually true; otherwise that stale row would deny the
  /// next `sendRequest`. The friendship delete comes first and is the write that
  /// matters; a failure to clear the request leaves inert residue that
  /// `sendRequest` self-heals anyway.
  Future<void> removeFriend({
    required String uid,
    required String otherUid,
  }) async {
    await _friendships.doc(friendshipId(uid, otherUid)).delete();
    await _deleteRequestBetween(uid, otherUid);
  }

  /// Best-effort delete of any request row in either direction between two
  /// users. A delete on an absent doc is refused by the `isParty` rule (a null
  /// resource has no parties) and simply ignored.
  Future<void> _deleteRequestBetween(String a, String b) async {
    for (final id in [
      friendRequestId(fromUid: a, toUid: b),
      friendRequestId(fromUid: b, toUid: a),
    ]) {
      try {
        await _requests.doc(id).delete();
      } catch (_) {}
    }
  }
}
