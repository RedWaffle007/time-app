import 'package:cloud_firestore/cloud_firestore.dart';

/// The per-user soft-archive set, stored at `users/{uid}/state/archived` as a
/// single `items` map of `itemId → archivedAt` (DECISIONS.md "Group D — CHOSEN").
///
/// **The flag lives in the ARCHIVER's own subtree, never on the shared item
/// doc.** That is the whole design: archiving is a view preference, so it must
/// not require write access to a document the other party also reads, and it
/// must be structurally impossible to hide something in someone else's view.
/// The Firestore rule is correspondingly trivial — owner-only, the same shape as
/// `fcmTokens`.
///
/// One doc holding a map (rather than a doc per item) is one cheap read to
/// filter every surface, `archivedAt` comes free, and unarchive is deleting a
/// key. `users/{uid}/archivedItems/{itemId}` is the drop-in scale-up if the map
/// ever gets large; it is not needed at this scale.
///
/// Keys are raw Firestore auto-ids (~119 bits of randomness), not
/// `targetUid_itemId`. A planner archives items living under several different
/// targets, so in principle the key space is a union — but two auto-ids
/// colliding is not a thing that happens, and a composite key would have to be
/// threaded through every call site to buy nothing.
class ArchiveRepository {
  ArchiveRepository(this._db);

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('users').doc(uid).collection('state').doc('archived');

  /// Streams the archived item ids. Emits an empty set when the doc doesn't
  /// exist yet — the common case, since the doc is only created on first
  /// archive.
  ///
  /// This stream may still fail (offline before the first cache fill, or rules
  /// not yet deployed). Isolating that failure is NOT done here; it is done once
  /// in `archive_providers.dart`, at the seam where the archive joins the
  /// schedule. See the comment there.
  Stream<Set<String>> watchArchivedIds(String uid) {
    return _doc(uid).snapshots().map((snap) {
      final items = snap.data()?['items'];
      if (items is! Map) return const <String>{};
      return items.keys.cast<String>().toSet();
    });
  }

  /// Hides [itemId] from this user's own views. Merge-writes so the doc is
  /// created on first use and other keys are untouched.
  Future<void> archive(String uid, String itemId) {
    return _doc(uid).set({
      'items': {itemId: FieldValue.serverTimestamp()},
    }, SetOptions(merge: true));
  }

  /// Puts [itemId] back. Archive is reversible by design — one-way hiding would
  /// feel like the "delete" this feature exists to avoid, and since the record
  /// is untouched, reversibility is free.
  Future<void> unarchive(String uid, String itemId) {
    return _doc(uid).set({
      'items': {itemId: FieldValue.delete()},
    }, SetOptions(merge: true));
  }
}
