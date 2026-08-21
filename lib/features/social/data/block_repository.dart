import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/friend_request.dart';
import '../domain/social_ids.dart';
import '../domain/user_block.dart';

/// Blocking, and the cleanup that has to come with it.
///
/// **A block is not one write.** Placing the block document is the easy part;
/// what makes the feature mean anything is severing the standing permissions
/// that already exist between the two people. In this app those permissions are
/// unusually consequential — a live planner grant lets someone put items on
/// your calendar and fire alarms on your phone — so a block that left one
/// standing would be worse than no block at all.
///
/// The order below is chosen so that every intermediate state is safe:
///
///   1. **the block document first.** It is what every gate reads, so from this
///      moment the two are invisible to each other even if nothing else
///      succeeds. Everything after it is cleanup of things that are already
///      unreachable.
///   2. planner grants, both directions.
///   3. the friendship.
///   4. any pending request, both directions.
///
/// A failure part-way therefore leaves a live block with some stale-but-inert
/// residue behind it, and re-running [block] cleans up the rest. The reverse
/// order — tidy first, block last — would leave a window in which the
/// relationship is half-dismantled and the block is not yet in force.
///
/// **What is deliberately NOT touched: existing schedule items.** They are a
/// shared record of something that was consented to, and rewriting them would
/// be the "delete for me" dishonesty `DECISIONS.md` rejected on the archive
/// feature. Revoking the grants stops anything new; the existing withdraw and
/// reject controls handle what is already there.
class BlockRepository {
  BlockRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _blocks =>
      _db.collection('blocks');

  // --- reads ---

  /// Everyone [uid] has blocked. Their own list, for a manage-blocks screen.
  Stream<List<UserBlock>> watchMyBlocks(String uid) {
    return _blocks
        .where('blockerUid', isEqualTo: uid)
        .snapshots()
        .map((s) => s.docs.map(UserBlock.fromDoc).toList());
  }

  /// Whether a block exists in either direction, live.
  ///
  /// **Both directions, always.** The record is one-way but enforcement is
  /// symmetric — a one-way check would let the blocked party carry on reading
  /// the blocker's profile, which is the whole thing the feature is for.
  ///
  /// Two document listeners rather than a query, because both ids are
  /// computable and a `get` on a known path is what the security rules do too.
  Stream<({bool iBlocked, bool theyBlocked})> watchBlockPair({
    required String viewerUid,
    required String otherUid,
  }) {
    if (viewerUid == otherUid) {
      return Stream.value((iBlocked: false, theyBlocked: false));
    }
    final mine = _blocks
        .doc(blockId(blockerUid: viewerUid, blockedUid: otherUid))
        .snapshots();
    final theirs = _blocks
        .doc(blockId(blockerUid: otherUid, blockedUid: viewerUid))
        .snapshots();

    // Combined by hand rather than with an Rx package: two snapshot streams,
    // each emitting the current state, so the latest of each is all that is
    // needed. Seeded false/false so the pair emits as soon as EITHER side
    // answers, instead of waiting for both — a profile must not sit on a
    // spinner because one of two listeners is slow.
    var iBlocked = false;
    var theyBlocked = false;
    final controller = StreamController<({bool iBlocked, bool theyBlocked})>();
    final subs = [
      mine.listen((d) {
        iBlocked = d.exists;
        if (!controller.isClosed) {
          controller.add((iBlocked: iBlocked, theyBlocked: theyBlocked));
        }
      }, onError: controller.addError),
      theirs.listen((d) {
        theyBlocked = d.exists;
        if (!controller.isClosed) {
          controller.add((iBlocked: iBlocked, theyBlocked: theyBlocked));
        }
      }, onError: controller.addError),
    ];
    controller.onCancel = () async {
      for (final s in subs) {
        await s.cancel();
      }
    };
    return controller.stream;
  }

  // --- writes ---

  /// Block [blockedUid], and sever everything standing between the two.
  /// See the class doc for why the steps are in this order.
  Future<void> block({
    required String blockerUid,
    required String blockedUid,
  }) async {
    // 1. The block itself, first and alone.
    await _blocks
        .doc(blockId(blockerUid: blockerUid, blockedUid: blockedUid))
        .set({
      'blockerUid': blockerUid,
      'blockedUid': blockedUid,
      'createdAt': FieldValue.serverTimestamp(),
    });

    // 2. Planner grants, both directions. The most consequential residue: a
    //    live grant is permission to schedule someone's day and ring their
    //    phone. Best-effort — a grant we cannot reach is inert anyway, because
    //    creating an item additionally requires both parties to share a group.
    await _revokeGrantsBetween(blockerUid, blockedUid);

    // 3. The friendship.
    await _db
        .collection('friendships')
        .doc(friendshipId(blockerUid, blockedUid))
        .delete();

    // 4. Pending requests, both directions.
    await _cancelPendingRequest(from: blockerUid, to: blockedUid);
    await _cancelPendingRequest(from: blockedUid, to: blockerUid);
  }

  /// Lift a block. Only the blocker may, which the rules enforce.
  ///
  /// **Nothing is restored.** The friendship, the grants and the requests that
  /// the block tore down stay torn down — re-blocking must not be a way to
  /// silently re-arm someone's permission over your calendar, and "undo"
  /// semantics here would mean exactly that. The two are simply strangers
  /// again, free to send a fresh request.
  Future<void> unblock({
    required String blockerUid,
    required String blockedUid,
  }) {
    return _blocks
        .doc(blockId(blockerUid: blockerUid, blockedUid: blockedUid))
        .delete();
  }

  /// Revoke every live grant between two users, in both directions.
  ///
  /// Queried through the collection group, because grants live under whichever
  /// group they were made in and neither party knows which groups those are.
  /// The collection-group read rule is resource-scoped to grants naming the
  /// caller, so each query below returns only rows this user is a party to —
  /// which is also exactly the set they have standing to revoke.
  Future<void> _revokeGrantsBetween(String callerUid, String otherUid) async {
    final grants = _db.collectionGroup('plannerGrants');

    for (final (field, counterpart) in [
      ('plannerUid', 'targetUid'),
      ('targetUid', 'plannerUid'),
    ]) {
      final snap = await grants
          .where(field, isEqualTo: callerUid)
          .where('granted', isEqualTo: true)
          .get();
      for (final doc in snap.docs) {
        if (doc.data()[counterpart] != otherUid) continue;
        await doc.reference.update({
          'granted': false,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    }
  }

  Future<void> _cancelPendingRequest({
    required String from,
    required String to,
  }) async {
    final ref = _db
        .collection('friendRequests')
        .doc(friendRequestId(fromUid: from, toUid: to));
    final snap = await ref.get();
    if (!snap.exists) return;
    if (snap.data()?['status'] != FriendRequestStatus.pending.name) return;
    await ref.set({
      'status': FriendRequestStatus.cancelled.name,
      'decidedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
