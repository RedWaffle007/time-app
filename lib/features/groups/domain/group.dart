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
    this.adminUids = const [],
    this.lastAdmittedUid,
    this.avatar,
  });

  final String id;
  final String name;
  final String ownerUid;

  /// Short code others type to join this group.
  final String joinCode;
  final List<String> memberUids;

  /// Admins besides the creator (WhatsApp-style, Batch G item 3). Only the
  /// creator changes it. A group written before admins existed has none.
  final List<String> adminUids;

  /// The creator is always an admin; others only while still members.
  bool isAdmin(String uid) =>
      memberUids.contains(uid) && (uid == ownerUid || adminUids.contains(uid));

  /// Audit pointer used by Firestore rules to bind a roster addition to its
  /// admin-approved request. It is not membership state.
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
      adminUids: List<String>.from(d['adminUids'] ?? const []),
      lastAdmittedUid: d['lastAdmittedUid'] as String?,
      avatar: ProfileAvatar.fromMap(d['avatar'] as Map<String, dynamic>?),
    );
  }
}
