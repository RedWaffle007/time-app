import 'package:cloud_firestore/cloud_firestore.dart';

/// A trusted circle. Stored at `groups/{id}`.
///
/// `memberUids` is a denormalized array so we can query "groups I'm in" with a
/// single arrayContains query; per-member detail lives in the members subcollection.
class Group {
  const Group({
    required this.id,
    required this.name,
    required this.ownerUid,
    required this.joinCode,
    required this.memberUids,
  });

  final String id;
  final String name;
  final String ownerUid;

  /// Short code others type to join this group.
  final String joinCode;
  final List<String> memberUids;

  factory Group.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return Group(
      id: doc.id,
      name: (d['name'] ?? '') as String,
      ownerUid: (d['ownerUid'] ?? '') as String,
      joinCode: (d['joinCode'] ?? '') as String,
      memberUids: List<String>.from(d['memberUids'] ?? const []),
    );
  }
}
