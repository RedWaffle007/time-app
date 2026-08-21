import 'package:cloud_firestore/cloud_firestore.dart';

/// One user blocking another. Stored at `blocks/{blockerUid}_{blockedUid}`.
///
/// **The record is directed; the enforcement is symmetric.** Only the blocker
/// may create or lift it, but every gate in the app checks BOTH directions —
/// `blocks/{a}_{b}` and `blocks/{b}_{a}` — so being blocked hides you just as
/// thoroughly as blocking does. A one-way check would let the blocked party
/// keep reading the blocker's profile, which is the entire thing the feature is
/// for.
///
/// What a block does, precisely (and what it does not):
///
///   * neither party can see the other's profile, stats, or search results;
///   * neither can send the other a friend request;
///   * any existing friendship is deleted, and any pending request cancelled;
///   * any live planner grant between them is revoked, both directions.
///
/// What it deliberately does NOT do: retract schedule items that already exist.
/// Those are a shared record of something that was consented to, and silently
/// rewriting history is the "delete for me" failure `DECISIONS.md` rejected on
/// the archive feature. The grant revocation stops anything NEW being created,
/// and existing items remain individually withdrawable and rejectable through
/// the controls that already exist.
class UserBlock {
  const UserBlock({
    required this.id,
    required this.blockerUid,
    required this.blockedUid,
    this.createdAt,
  });

  final String id;

  /// Who placed the block. The only person who may lift it.
  final String blockerUid;

  /// Who is blocked.
  final String blockedUid;

  final DateTime? createdAt;

  factory UserBlock.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return UserBlock(
      id: doc.id,
      blockerUid: (d['blockerUid'] ?? '') as String,
      blockedUid: (d['blockedUid'] ?? '') as String,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
