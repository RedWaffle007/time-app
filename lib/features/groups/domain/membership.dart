import 'package:cloud_firestore/cloud_firestore.dart';

/// A member of a group. Stored at `groups/{id}/members/{uid}`.
///
/// The name is denormalized (snapshot at join time) so member lists don't need
/// an extra lookup per member.
class Membership {
  const Membership({required this.uid, required this.name});

  final String uid;
  final String name;

  factory Membership.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return Membership(
      uid: doc.id,
      name: (d['name'] ?? '') as String,
    );
  }
}
