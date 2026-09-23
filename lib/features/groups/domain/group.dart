import 'package:cloud_firestore/cloud_firestore.dart';

import '../../social/domain/avatar.dart';

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
    this.lastAdmittedUid,
    this.avatar,
  });

  final String id;
  final String name;
  final String ownerUid;

  /// Short code others type to join this group.
  final String joinCode;
  final List<String> memberUids;

  /// Audit pointer used by Firestore rules to bind a roster addition to its
  /// unanimously approved request. It is not membership state.
  final String? lastAdmittedUid;

  /// Optional group picture. Legacy groups omit this and render their initial.
  final ProfileAvatar? avatar;

  String? get displayAvatarUrl =>
      avatar?.isDisplayable == true ? avatar!.url : null;

  factory Group.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return Group(
      id: doc.id,
      name: (d['name'] ?? '') as String,
      ownerUid: (d['ownerUid'] ?? '') as String,
      joinCode: (d['joinCode'] ?? '') as String,
      memberUids: List<String>.from(d['memberUids'] ?? const []),
      lastAdmittedUid: d['lastAdmittedUid'] as String?,
      avatar: ProfileAvatar.fromMap(d['avatar'] as Map<String, dynamic>?),
    );
  }
}
