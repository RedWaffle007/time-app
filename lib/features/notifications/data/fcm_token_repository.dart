import 'package:cloud_firestore/cloud_firestore.dart';

/// Per-device FCM token storage at `users/{uid}/fcmTokens/{token}`.
///
/// The token string is the doc id, so re-registering the same device is
/// idempotent and server-side cleanup of a dead token is an O(1) delete.
class FcmTokenRepository {
  FcmTokenRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      _db.collection('users').doc(uid).collection('fcmTokens');

  /// Registers (or re-registers) this device's token.
  ///
  /// `createdAt` is WRITE-ONCE — it means "first registered", so it is only set
  /// when the doc doesn't exist yet. It used to be re-stamped on every merge
  /// write, which made it silently mean "last write" and read *later* than the
  /// doc's own createTime (see DECISIONS.md 2026-07-24). `lastRegisteredAt` is
  /// the field that legitimately moves: it answers "is this device still
  /// checking in?", which is exactly the question nobody could answer during the
  /// six days no token existed at all.
  Future<void> saveToken(String uid, String token) async {
    final doc = _col(uid).doc(token);
    final existing = await doc.get();
    await doc.set({
      'token': token,
      'platform': 'android',
      if (!existing.exists) 'createdAt': FieldValue.serverTimestamp(),
      'lastRegisteredAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> deleteToken(String uid, String token) {
    return _col(uid).doc(token).delete();
  }
}
