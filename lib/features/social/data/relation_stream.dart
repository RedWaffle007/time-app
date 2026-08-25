import 'package:cloud_firestore/cloud_firestore.dart';

/// A live relationship read on a **computed document id**, hardened against the
/// one Firestore denial that is really an absence.
///
/// Every social relationship (`friendships/{sortedPair}`,
/// `friendRequests/{from_to}`, `blocks/{blocker_blocked}`) lives at an id
/// computed from the two uids, and every read rule for it is *"a party may
/// read"* — a condition that dereferences `resource.data`. When the document
/// does **not** exist, `resource` is `null`, the rule errors, and the listener
/// receives `permission-denied` rather than an empty snapshot. (Confirmed
/// against the deployed rules — see `firestore-tests/repro_bugs.test.mjs` and
/// DECISIONS.md "Cross-device relationship + planning denials (2026-08-24)".)
///
/// For these reads that denial is unambiguous: the id always names the caller,
/// so a document the caller could not read cannot exist at this id — a
/// `permission-denied` therefore means **the document is absent**, i.e. there
/// is no relationship. This maps that single error code to [absent]. Any other
/// error (a genuine outage, a rules change) is rethrown untouched.
///
/// The mapping does **not** loosen the rules — a real non-party reading someone
/// else's relationship is still denied server-side; this only stops a profile
/// screen from spinning forever on the normal "these two are strangers" case.
///
/// **Reactivity note:** a Firestore listener terminates on error, so once a
/// relationship is absent this stream ends after yielding [absent]. If the
/// relationship later forms while the same screen is open (e.g. the other party
/// accepts a request mid-view), the change is picked up on the next rebuild of
/// the provider, not on this subscription. Acceptable for a short-lived profile
/// screen; the alternative is deriving these from the caller-scoped query
/// streams, which is the larger refactor deferred in the same DECISIONS entry.
Stream<T> relationStreamAbsentOnDenied<T>(
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots,
  T Function(DocumentSnapshot<Map<String, dynamic>>) present,
  T absent,
) async* {
  try {
    await for (final snapshot in snapshots) {
      yield present(snapshot);
    }
  } on FirebaseException catch (e) {
    if (e.code == 'permission-denied') {
      yield absent;
    } else {
      rethrow;
    }
  }
}

/// Whether an error is the "computed-id document is absent" denial that
/// [relationStreamAbsentOnDenied] treats as absence. Exposed for callers that
/// combine multiple listeners by hand (see `BlockRepository.watchBlockPair`).
bool isAbsenceDenial(Object error) =>
    error is FirebaseException && error.code == 'permission-denied';
