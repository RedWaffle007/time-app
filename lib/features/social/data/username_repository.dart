import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/username.dart';

/// Thrown when a handle cannot be claimed. Carries a message already written
/// for the user, in the same spirit as `ChatbotFailure`.
class UsernameUnavailable implements Exception {
  const UsernameUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// **Username uniqueness, via a reservation collection.**
///
/// Firestore cannot express "this field is unique" — there is no unique index
/// and rules cannot run a query. Uniqueness has to be built out of the one
/// primitive that IS atomic: a document id.
///
/// So the canonical handle is the **document id** of a reservation at
/// `usernames/{handle}`, holding only the uid that owns it. Two people racing
/// for the same handle race for the same document, and Firestore serialises
/// that for us.
///
/// This is the same pattern as `joinCodes/{CODE}` in `group_repository.dart`,
/// and for the same reason — that collection exists so a join can resolve a
/// code without being allowed to enumerate every group. Here the enumeration
/// being prevented is of users.
///
/// **`list` is denied on this collection too**, which shapes the search
/// feature: [lookup] is an exact-match `get` on a handle you already know, and
/// there is no prefix or fuzzy search. That is not a limitation to work around
/// later — `users` had `allow list: if false` applied deliberately, because
/// listing it leaked every user's name, home timezone and quiet-hours window
/// (i.e. when they sleep). Any prefix search would need list access on
/// something, and re-opening it here would re-open exactly that hole through a
/// different door.
class UsernameRepository {
  UsernameRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _usernames =>
      _db.collection('usernames');

  DocumentReference<Map<String, dynamic>> _user(String uid) =>
      _db.collection('users').doc(uid);

  /// Resolve a handle to a uid, or null if nobody holds it.
  ///
  /// The one search primitive the app has. Case-insensitive because the caller
  /// canonicalises first — typing `Ana` finds `ana`.
  Future<String?> lookup(String rawHandle) async {
    final handle = canonicalUsername(rawHandle);
    if (!isValidUsername(handle)) return null;
    final doc = await _usernames.doc(handle).get();
    return doc.data()?['uid'] as String?;
  }

  /// Whether [rawHandle] is free for [uid] to take.
  ///
  /// **Advisory only, and the UI must treat it that way.** Two users can both
  /// see "available" a moment before one of them claims it; only [claim]
  /// decides. This exists to give the edit field a live tick, not to gate the
  /// write — which is why [claim] re-checks inside a transaction rather than
  /// trusting whatever this returned.
  Future<bool> isAvailable(String rawHandle, {required String uid}) async {
    final handle = canonicalUsername(rawHandle);
    if (!isValidUsername(handle)) return false;
    final doc = await _usernames.doc(handle).get();
    if (!doc.exists) return true;
    // Re-claiming your own handle is a no-op, not a collision.
    return doc.data()?['uid'] == uid;
  }

  /// Claim [rawHandle] for [uid], releasing [previousHandle] if there is one.
  ///
  /// **Two steps, and it cannot be one.** The reservation moves inside a
  /// transaction; the mirror on `users/{uid}` is written afterwards, as a
  /// separate operation.
  ///
  /// The reason is a property of Firestore security rules that is easy to get
  /// wrong: **`exists()` and `get()` inside a rule see the last COMMITTED
  /// state, never the pending writes of the transaction being evaluated.** The
  /// rule guarding the mirror asks "does this user actually hold a reservation
  /// for the handle they are claiming to display?" — and if the mirror write
  /// shared a transaction with the reservation write, that check would run
  /// against a world where the reservation does not exist yet, and every claim
  /// would be denied.
  ///
  /// So:
  ///
  ///   1. **transaction** — read `usernames/{new}`; refuse if someone else
  ///      holds it; write it; delete `usernames/{old}`. This is where
  ///      uniqueness is won: two people racing for one handle race for one
  ///      document, and Firestore serialises that.
  ///   2. **plain write** — mirror the handle onto `users/{uid}`, now that the
  ///      reservation is committed and the rule can see it.
  ///
  /// Ordering inside the transaction matters for the same class of reason:
  /// creating before deleting means a crash can only ever leave the user
  /// holding *two* reservations, which is inert — the profile mirror names
  /// which one is live, and the orphan is re-claimable only by its owner.
  /// Deleting first would open a window in which they hold none.
  ///
  /// A failure BETWEEN the two steps leaves the reservation held and the
  /// profile still showing the old handle. That is visible, harmless, and
  /// fixed by pressing Save again — step 1 becomes a no-op and step 2 lands.
  ///
  /// Throws [UsernameUnavailable] when the handle is taken or invalid.
  Future<void> claim({
    required String uid,
    required String rawHandle,
    String? previousHandle,
  }) async {
    final handle = canonicalUsername(rawHandle);
    final problem = validateUsername(handle);
    if (problem != UsernameProblem.none) {
      throw UsernameUnavailable(describeUsernameProblem(problem));
    }

    final previous =
        previousHandle == null ? null : canonicalUsername(previousHandle);
    if (previous == handle) return; // Nothing to do.

    // Step 1 — the reservation. Uniqueness is decided here.
    await _db.runTransaction((tx) async {
      final ref = _usernames.doc(handle);
      final snap = await tx.get(ref);

      if (snap.exists && snap.data()?['uid'] != uid) {
        throw const UsernameUnavailable('That username is already taken.');
      }

      tx.set(ref, {
        'uid': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (previous != null && previous.isNotEmpty) {
        tx.delete(_usernames.doc(previous));
      }
    });

    // Step 2 — the mirror, separately, so the rule guarding it can see the
    // reservation committed above.
    await _user(uid).set({
      'username': handle,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}

/// User-facing copy for a validation failure.
///
/// Lives beside the repository rather than in `username.dart` so the domain
/// stays free of presentation. The numbers are interpolated from the constants
/// so the message can never disagree with the rule it describes.
String describeUsernameProblem(UsernameProblem problem) {
  switch (problem) {
    case UsernameProblem.none:
      return '';
    case UsernameProblem.tooShort:
      return 'Usernames need at least $kUsernameMinLength characters.';
    case UsernameProblem.tooLong:
      return 'Usernames can be at most $kUsernameMaxLength characters.';
    case UsernameProblem.badCharacters:
      return 'Use only lowercase letters, numbers and underscores.';
    case UsernameProblem.mustStartWithLetter:
      return 'Usernames have to start with a letter.';
    case UsernameProblem.reserved:
      return 'That username is reserved.';
  }
}
