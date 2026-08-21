import 'package:cloud_firestore/cloud_firestore.dart';

import 'social_ids.dart';

/// An accepted, mutual friendship. Stored at `friendships/{sortedPairId}` —
/// see [friendshipId] for why the id is sorted rather than an auto-id.
///
/// One document per pair, not one per direction. A friendship is a single fact
/// about two people; storing it twice would create a state where half of it can
/// be deleted, and there is no honest way to render "Ana thinks they are
/// friends but Ben does not".
///
/// [participants] duplicates [uidA]/[uidB] as an array purely so the client can
/// run `where('participants', arrayContains: myUid)` to list a friends list.
/// The rules never read it — they read the id — so the denormalisation carries
/// no security weight and cannot drift into one.
class Friendship {
  const Friendship({
    required this.id,
    required this.uidA,
    required this.uidB,
    this.createdAt,
  });

  final String id;

  /// The lexicographically smaller uid. Which of the two people this is carries
  /// **no meaning** — it is a sort key, not a role. Use [otherUid].
  final String uidA;

  /// The lexicographically larger uid. See [uidA].
  final String uidB;

  final DateTime? createdAt;

  /// The friend, from [me]'s point of view.
  ///
  /// Every screen wants this and none of them want `uidA`/`uidB`, which is the
  /// whole point of exposing it here rather than letting each caller re-derive
  /// which half of the pair it is looking at.
  String otherUid(String me) => uidA == me ? uidB : uidA;

  bool involves(String uid) => uid == uidA || uid == uidB;

  factory Friendship.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return Friendship(
      id: doc.id,
      uidA: (d['uidA'] ?? '') as String,
      uidB: (d['uidB'] ?? '') as String,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
