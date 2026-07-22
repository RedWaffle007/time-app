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

  Future<void> saveToken(String uid, String token) {
    return _col(uid).doc(token).set({
      'token': token,
      'platform': 'android',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> deleteToken(String uid, String token) {
    return _col(uid).doc(token).delete();
  }
}
