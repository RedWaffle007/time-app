/// **Deterministic document ids for two-party relationships.**
///
/// This file is three functions and it is the most load-bearing thing in the
/// social layer. The reason is a hard property of Firestore security rules:
///
/// > **Rules can `exists()` a path they can construct. Rules cannot run a
/// > query.**
///
/// So "may this person read my stats?" is answerable in a rule only if the
/// answer lives at an address the rule can *compute* from the two uids in hand.
/// A friendship stored under an auto-id, discoverable only by querying
/// `where('participants', arrayContains: …)`, is invisible to the rules engine
/// — and the privacy toggle becomes unenforceable, which is to say it becomes a
/// lie in the UI.
///
/// Hence: the id IS the relationship.
///
///   * [friendshipId] sorts the pair, because friendship is **symmetric** —
///     one edge, and both parties must compute the same address for it.
///   * [friendRequestId] does **not** sort, because a request is **directed** —
///     `ana → ben` and `ben → ana` are genuinely different documents, and
///     collapsing them would make a crossing pair of requests overwrite each
///     other.
///   * [blockId] does not sort either, for the same reason: A blocking B is not
///     B blocking A, and both may exist at once.
///
/// The separator is `_`, matching [PlannerGrant.docId] which already uses it.
/// Firebase uids are 28 characters of `[A-Za-z0-9]` with no underscore, so the
/// join is unambiguous and reversible.
library;

/// The one document representing "these two are friends". Symmetric: both
/// parties compute the same id regardless of who calls.
///
/// Sorting is what makes that true. With `a_b` written by one side and `b_a` by
/// the other, two documents would describe one friendship and every rule would
/// have to check both — doubling the `exists()` cost on the hot path and
/// leaving a state where unfriending removes only half the edge.
String friendshipId(String uidA, String uidB) {
  assert(uidA != uidB, 'a user cannot befriend themselves');
  return uidA.compareTo(uidB) < 0 ? '${uidA}_$uidB' : '${uidB}_$uidA';
}

/// A pending request FROM one user TO another. Directed — do not sort.
///
/// Deterministic rather than auto-id so sending twice is idempotent: the second
/// tap overwrites the first document instead of creating a duplicate the
/// recipient has to decline twice. It also gives the rules a computable address
/// for "is there already a request from me to them?".
String friendRequestId({required String fromUid, required String toUid}) {
  assert(fromUid != toUid, 'a user cannot friend-request themselves');
  return '${fromUid}_$toUid';
}

/// A block placed BY one user ON another. Directed — do not sort.
///
/// Deliberately one-directional as a *record* even though enforcement is
/// bidirectional. Who blocked whom is a fact worth keeping: only the blocker
/// may lift it, and a symmetric document could not express that.
String blockId({required String blockerUid, required String blockedUid}) {
  assert(blockerUid != blockedUid, 'a user cannot block themselves');
  return '${blockerUid}_$blockedUid';
}
