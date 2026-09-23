import 'package:cloud_firestore/cloud_firestore.dart';

/// The durable six-hour inactivity timer for one account.
///
/// This is intentionally separate from `users/{uid}`: profiles are readable by
/// any signed-in user who knows the uid, while activity timestamps are private
/// operational data. The client writes only the two activity-owned fields; the
/// Worker owns the delivery cursor and lease fields on the same document.
abstract interface class InactivityRepository {
  Future<void> recordActivity(String uid, DateTime occurredAtUtc);
}

class FirestoreInactivityRepository implements InactivityRepository {
  FirestoreInactivityRepository(this._db);

  final FirebaseFirestore _db;

  static const inactivityDelay = Duration(hours: 6);

  @override
  Future<void> recordActivity(String uid, DateTime occurredAtUtc) async {
    final activityAt = occurredAtUtc.toUtc();
    final ref = _db.collection('inactivityStates').doc(uid);

    // A delayed write from this device must not move a newer multi-device
    // activity timestamp backwards. The Worker fields are deliberately left
    // untouched by this merge transaction.
    await _db.runTransaction((transaction) async {
      final current = await transaction.get(ref);
      final previous = current.data()?['lastActivityAt'] as Timestamp?;
      if (previous != null && !activityAt.isAfter(previous.toDate())) return;

      transaction.set(ref, {
        'uid': uid,
        'lastActivityAt': Timestamp.fromDate(activityAt),
        'nextNotificationAt': Timestamp.fromDate(
          activityAt.add(inactivityDelay),
        ),
      }, SetOptions(merge: true));
    });
  }
}
