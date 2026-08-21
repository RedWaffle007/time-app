/// **What one user may see and do on another's profile.**
///
/// A pure function, and — this is the important part — **a mirror of
/// `firestore.rules`, never a substitute for it.** The rules are the only
/// enforcement. This exists so the UI can grey out a button and explain itself
/// instead of firing a write that comes back `PERMISSION_DENIED` with nothing
/// to show the user.
///
/// The two must agree. When they drift, the direction of the drift decides how
/// bad it is:
///
///   * **client stricter than rules** — a control is hidden that would have
///     worked. Mildly annoying, invisible, safe.
///   * **client looser than rules** — a control is offered that always fails.
///     The user taps, nothing happens, and there is no error worth showing.
///
/// So when in doubt this file is the stricter of the two. The rules block in
/// `firestore.rules` quotes this file by name for the same reason.
library;

/// The signed-in user's standing relative to a profile they are looking at.
///
/// Ordered by precedence in [relationBetween]: the first that applies wins, and
/// the block states come first because a block overrides every other fact about
/// the pair.
enum ProfileRelation {
  /// The user's own profile.
  self,

  /// The viewer has blocked this person.
  blocking,

  /// This person has blocked the viewer.
  ///
  /// **Rendered identically to [notFound].** Telling someone they have been
  /// blocked hands them the one piece of information a block exists to
  /// withhold, and turns the feature into a notification. The distinction is
  /// kept in the model because the *viewer's* own controls differ — there is
  /// nothing for them to un-block — but it must never reach the screen as text.
  blockedBy,

  /// Accepted, mutual friends.
  friend,

  /// The viewer has a pending outgoing request to this person.
  requestSent,

  /// This person has a pending request to the viewer, awaiting their decision.
  requestReceived,

  /// No relationship at all.
  none,
}

/// Everything the profile screen needs to decide, in one value.
class ProfileVisibility {
  const ProfileVisibility({
    required this.relation,
    required this.canSeeStats,
    required this.canSendRequest,
    required this.canBlock,
  });

  final ProfileRelation relation;

  /// Whether the numbers render, or the section renders withheld.
  final bool canSeeStats;

  /// Whether "Add friend" is offered.
  final bool canSendRequest;

  /// Whether "Block" is offered. False on your own profile and when already
  /// blocking; **true when [blockedBy]**, deliberately — a person who has been
  /// blocked must still be able to block back, and refusing that would leak the
  /// block by making the control vanish.
  final bool canBlock;

  bool get isSelf => relation == ProfileRelation.self;

  /// Whether the profile should be treated as unreachable. Both block
  /// directions collapse to this so no screen can accidentally render the
  /// difference.
  bool get isUnreachable =>
      relation == ProfileRelation.blocking ||
      relation == ProfileRelation.blockedBy;
}

/// Derive the relationship. Inputs are plain booleans so this is trivially
/// testable and cannot reach for a repository.
ProfileRelation relationBetween({
  required String viewerUid,
  required String profileUid,
  required bool isFriend,
  required bool viewerBlockedThem,
  required bool theyBlockedViewer,
  required bool outgoingRequestPending,
  required bool incomingRequestPending,
}) {
  if (viewerUid == profileUid) return ProfileRelation.self;
  // Blocks first, in both directions, before anything else is consulted. A
  // stale friendship or request row must never out-rank a block — and one can
  // exist, because blocking cleans up asynchronously across several documents.
  if (viewerBlockedThem) return ProfileRelation.blocking;
  if (theyBlockedViewer) return ProfileRelation.blockedBy;
  if (isFriend) return ProfileRelation.friend;
  if (outgoingRequestPending) return ProfileRelation.requestSent;
  if (incomingRequestPending) return ProfileRelation.requestReceived;
  return ProfileRelation.none;
}

/// The full decision, given the relationship and the profile's own privacy
/// setting.
///
/// [isPublic] is the owner's toggle. Public means "anyone signed in may see my
/// numbers" — which is what a future leaderboard needs. Private means friends
/// only. Neither setting can expose anything to a blocked party.
ProfileVisibility visibilityFor({
  required ProfileRelation relation,
  required bool isPublic,
}) {
  switch (relation) {
    case ProfileRelation.self:
      return const ProfileVisibility(
        relation: ProfileRelation.self,
        canSeeStats: true,
        canSendRequest: false,
        canBlock: false,
      );

    case ProfileRelation.blocking:
    case ProfileRelation.blockedBy:
      return ProfileVisibility(
        relation: relation,
        canSeeStats: false,
        canSendRequest: false,
        // See [ProfileVisibility.canBlock]: blocking back must stay available.
        canBlock: relation == ProfileRelation.blockedBy,
      );

    case ProfileRelation.friend:
      return const ProfileVisibility(
        relation: ProfileRelation.friend,
        canSeeStats: true,
        canSendRequest: false,
        canBlock: true,
      );

    // A pending request in either direction grants NOTHING. Sending a request
    // must not be a way to peek: if it were, a private profile would be
    // readable by anyone willing to tap Add friend and never follow up.
    case ProfileRelation.requestSent:
    case ProfileRelation.requestReceived:
    case ProfileRelation.none:
      return ProfileVisibility(
        relation: relation,
        canSeeStats: isPublic,
        canSendRequest: relation == ProfileRelation.none ||
            relation == ProfileRelation.requestReceived,
        canBlock: true,
      );
  }
}
