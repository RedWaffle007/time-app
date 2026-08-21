import 'package:cloud_firestore/cloud_firestore.dart';

import '../../social/domain/avatar.dart';
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

  /// Updates the social half of the profile — bio and the privacy toggle.
  ///
  /// **Separate from [updateProfile] on purpose.** That method is the identity
  /// form (name, timezone, quiet hours) and rewrites all of them together; this
  /// is a different form with a different Save. Folding them into one method
  /// would mean every privacy change also rewrote the user's timezone, and a
  /// concurrent edit on another device would silently lose one of them.
  ///
  /// [username] is NOT settable here. A handle is claimed through
  /// [UsernameRepository.claim], which writes the reservation and this mirror in
  /// one transaction — the mirror alone is worthless, and letting it be written
  /// on its own would produce a profile displaying a handle its owner does not
  /// hold.
  ///
  /// A null [bio] CLEARS it: a merge write cannot blank a field, so the null is
  /// turned into a delete, exactly as the quiet-hours fields do above.
  Future<void> updateSocialProfile({
    required String uid,
    required bool isPublic,
    String? bio,
  }) async {
    final trimmed = bio?.trim();
    await _users.doc(uid).set({
      'isPublic': isPublic,
      'bio': (trimmed == null || trimmed.isEmpty)
          ? FieldValue.delete()
          : trimmed,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Records an uploaded profile picture on the profile.
  ///
  /// Called only after [AvatarUploader.upload] has returned, i.e. after the
  /// bytes are stored and a URL exists. Writing this first and uploading second
  /// would put a URL on the profile that 404s for everyone who loads it before
  /// the upload lands.
  Future<void> setAvatar({
    required String uid,
    required ProfileAvatar avatar,
  }) {
    return _users.doc(uid).set({
      'avatar': avatar.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Removes the uploaded picture, falling the profile back to the Google photo
  /// (or to the initial-letter placeholder if there is none).
  ///
  /// Deletes the whole `avatar` map rather than blanking its `url`. A map with
  /// an empty url would still decode to a [ProfileAvatar] carrying a stale
  /// storage key and moderation state — a half-present picture that
  /// [UserProfile.displayAvatarUrl] would have to keep special-casing forever.
  Future<void> clearAvatar(String uid) {
    return _users.doc(uid).set({
      'avatar': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
