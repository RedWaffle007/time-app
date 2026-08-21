import 'package:cloud_firestore/cloud_firestore.dart';

/// Where a friend request has got to.
///
/// **`rejected` is a real, stored, terminal state — not a delete.** That is a
/// deliberate choice and it is the same one the schedule item makes with
/// `rejected` (see `data-model.md`): deleting the document would let the sender
/// re-send immediately and forever, turning "no" into a button that does
/// nothing. A kept row is also what lets the rules refuse a re-send without
/// having to trust the client to stop asking.
///
/// The cost, stated: a rejected row is a small permanent record that the
/// recipient said no. It is readable by both parties and by nobody else, and
/// the recipient can lift it by clearing the request — [cancelled] — if they
/// change their mind.
enum FriendRequestStatus {
  /// Sent, awaiting the recipient's decision.
  pending,

  /// Recipient accepted. A `friendships/{pairId}` document now exists.
  accepted,

  /// Recipient declined. Terminal until one of them clears it.
  rejected,

  /// Withdrawn by the SENDER before a decision, or cleared afterwards by
  /// either party. Distinct from [rejected] for exactly the reason
  /// `withdrawn` and `rejected` are distinct on a schedule item: they say who
  /// backed out, and the app should never render one as the other.
  cancelled,
}

/// A directed request from one user to another. Stored at
/// `friendRequests/{fromUid}_{toUid}`.
class FriendRequest {
  const FriendRequest({
    required this.id,
    required this.fromUid,
    required this.toUid,
    required this.status,
    this.createdAt,
    this.decidedAt,
  });

  final String id;
  final String fromUid;
  final String toUid;
  final FriendRequestStatus status;
  final DateTime? createdAt;
  final DateTime? decidedAt;

  bool get isPending => status == FriendRequestStatus.pending;

  /// True when [uid] is the one being asked — i.e. this belongs in their inbox
  /// and the Accept / Decline buttons are theirs to press.
  bool isIncomingFor(String uid) => toUid == uid;

  /// The other party, from [uid]'s point of view.
  String otherUid(String uid) => fromUid == uid ? toUid : fromUid;

  factory FriendRequest.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return FriendRequest(
      id: doc.id,
      fromUid: (d['fromUid'] ?? '') as String,
      toUid: (d['toUid'] ?? '') as String,
      status: FriendRequestStatus.values.firstWhere(
        (s) => s.name == d['status'],
        // An unreadable status must not present as actionable. Falling back to
        // `cancelled` renders an inert row; falling back to `pending` would
        // show Accept / Decline on a document whose real state is unknown.
        orElse: () => FriendRequestStatus.cancelled,
      ),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      decidedAt: (d['decidedAt'] as Timestamp?)?.toDate(),
    );
  }
}
