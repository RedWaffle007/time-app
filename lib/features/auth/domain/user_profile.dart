import 'package:cloud_firestore/cloud_firestore.dart';

/// A user's profile, stored at `users/{uid}` in Firestore.
///
/// Step 4 only needs name, avatar, and the required home timezone. Fields like
/// quietHours and fcmTokens (in the data model) are deferred to later steps.
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.name,
    required this.homeTimezone,
    this.avatarUrl,
  });

  final String uid;
  final String name;

  /// IANA timezone name, e.g. "Asia/Karachi". Required — the app's premise
  /// depends on knowing the target's local time.
  final String homeTimezone;

  final String? avatarUrl;

  /// A profile is only usable once it has both a name and a home timezone.
  bool get isComplete => name.trim().isNotEmpty && homeTimezone.trim().isNotEmpty;

  factory UserProfile.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const {};
    return UserProfile(
      uid: doc.id,
      name: (data['name'] ?? '') as String,
      homeTimezone: (data['homeTimezone'] ?? '') as String,
      avatarUrl: data['avatarUrl'] as String?,
    );
  }
}
