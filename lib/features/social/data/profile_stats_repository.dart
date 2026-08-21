import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/profile_stat.dart';

/// The published stats document at `users/{uid}/profileStats/summary`.
///
/// **Why publishing exists at all:** a visitor cannot compute your numbers.
/// Your schedule items live at `scheduleItems/{you}/items` and only you may
/// read that subtree — correctly, because it is your entire day, including
/// items you rejected. So the owner's device derives the numbers and writes
/// them here, and the visitor reads this one small document if the privacy rule
/// lets them.
///
/// **One document, not one per stat.** The same reasoning as
/// `ArchiveRepository`: a map in a single doc is one read to render the whole
/// section, and adding a stat is adding a key rather than a document, a rule
/// and an index. `users/{uid}/profileStats/{statId}` is the drop-in scale-up if
/// this ever needed per-stat permissions; nothing suggests it will.
///
/// **`summary` is a fixed id**, not an auto-id, for the same reason the
/// relationship ids are computable: a visitor has to be able to name the
/// document without listing the collection, and `list` is denied here.
class ProfileStatsRepository {
  ProfileStatsRepository(this._db);

  final FirebaseFirestore _db;

  /// The one document id in this collection.
  static const docId = 'summary';

  DocumentReference<Map<String, dynamic>> _doc(String uid) => _db
      .collection('users')
      .doc(uid)
      .collection('profileStats')
      .doc(docId);

  /// Someone's published stats. Emits [ProfileStatsSnapshot.empty] when the
  /// document does not exist — the normal state for a user who has never had
  /// stats published, which is everyone until their first publish.
  ///
  /// A permission failure is NOT swallowed here. The privacy gate is the point
  /// of the feature, so "you may not see this" has to be distinguishable from
  /// "there is nothing here" — the provider layer turns the former into a
  /// withheld section and the latter into placeholders.
  Stream<ProfileStatsSnapshot> watch(String uid) {
    return _doc(uid).snapshots().map(
          (d) => d.exists
              ? ProfileStatsSnapshot.fromDoc(d)
              : ProfileStatsSnapshot.empty,
        );
  }

  /// Write the signed-in user's own numbers.
  ///
  /// Owner-only, and the rules say so. Publishing someone else's stats would
  /// let anyone put any number on anyone's profile, which on a leaderboard is
  /// the whole game.
  ///
  /// A plain `set` rather than a merge: [values] is the complete, freshly
  /// computed set, and merging would leave a stat that has since been removed
  /// from the registry lingering on the document forever.
  Future<void> publish({
    required String uid,
    required Map<String, num> values,
    int version = 1,
  }) {
    return _doc(uid).set({
      'values': values,
      'version': version,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}
