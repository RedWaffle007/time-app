import 'package:cloud_firestore/cloud_firestore.dart';

/// Persists target-observed alarm events onto the shared schedule item.
abstract interface class AlarmTimelineRepository {
  Future<void> recordRang(String targetUid, String itemId, DateTime atUtc);
  Future<void> recordDismissed(String targetUid, String itemId, DateTime atUtc);
  Future<void> recordUnavailable(
    String targetUid,
    String itemId,
    DateTime atUtc,
  );
}

class FirestoreAlarmTimelineRepository implements AlarmTimelineRepository {
  FirestoreAlarmTimelineRepository(this._db);

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _item(String uid, String itemId) =>
      _db.collection('scheduleItems').doc(uid).collection('items').doc(itemId);

  @override
  Future<void> recordRang(String targetUid, String itemId, DateTime atUtc) =>
      _recordFirst(targetUid, itemId, 'rangAt', atUtc);

  @override
  Future<void> recordDismissed(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) => _recordFirst(targetUid, itemId, 'dismissedAt', atUtc);

  @override
  Future<void> recordUnavailable(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) => _recordFirst(targetUid, itemId, 'unavailableAt', atUtc);

  /// The first unavailable observation is immutable. Rang/dismissed retain
  /// their older earliest-observation repair behavior for audit-log backfills.
  Future<void> _recordFirst(
    String targetUid,
    String itemId,
    String field,
    DateTime atUtc,
  ) async {
    final ref = _item(targetUid, itemId);
    await _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      if (!snapshot.exists) return;
      final alarm = snapshot.data()?['alarm'] as Map<String, dynamic>?;
      final previous = alarm?[field] as Timestamp?;
      final at = atUtc.toUtc();
      if (previous != null &&
          (field == 'unavailableAt' || !at.isBefore(previous.toDate()))) {
        return;
      }
      transaction.update(ref, {
        'alarm.$field': Timestamp.fromDate(at),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }
}
