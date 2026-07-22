import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/user_profile.dart';

/// Reads/writes the `users/{uid}` profile document in Firestore.
class ProfileRepository {
  ProfileRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _users => _db.collection('users');

  /// Live stream of a user's profile. Emits null when the doc doesn't exist yet
  /// (i.e. the user has signed in but hasn't completed their profile).
  Stream<UserProfile?> watchProfile(String uid) {
    return _users.doc(uid).snapshots().map(
          (doc) => doc.exists ? UserProfile.fromDoc(doc) : null,
        );
  }

  /// First-time profile creation (from the complete-profile screen). Sets
  /// createdAt + updatedAt.
  Future<void> createProfile({
    required String uid,
    required String name,
    required String homeTimezone,
    String? avatarUrl,
  }) async {
    await _users.doc(uid).set({
      'name': name.trim(),
      'homeTimezone': homeTimezone,
      'avatarUrl': ?avatarUrl,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Edits an existing profile. Merges the changed fields and bumps updatedAt —
  /// deliberately does NOT touch createdAt.
  ///
  /// [quietHoursStartMinutes]/[quietHoursEndMinutes] are minutes-since-midnight
  /// in the user's own timezone. Pass both to set the window, or both null to
  /// CLEAR it — a merge write can't blank a field, so nulls delete it.
  Future<void> updateProfile({
    required String uid,
    required String name,
    required String homeTimezone,
    int? quietHoursStartMinutes,
    int? quietHoursEndMinutes,
  }) async {
    final quietSet =
        quietHoursStartMinutes != null && quietHoursEndMinutes != null;
    await _users.doc(uid).set({
      'name': name.trim(),
      'homeTimezone': homeTimezone,
      'quietHoursStartMinutes':
          quietSet ? quietHoursStartMinutes : FieldValue.delete(),
      'quietHoursEndMinutes':
          quietSet ? quietHoursEndMinutes : FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
