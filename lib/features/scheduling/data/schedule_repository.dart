import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/timezone/tz_resolver.dart';
import '../domain/schedule_item.dart';

/// Creates schedule items and drives their status/outcome transitions.
class ScheduleRepository {
  ScheduleRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _items(String targetUid) =>
      _db.collection('scheduleItems').doc(targetUid).collection('items');

  /// Planner creates an item. [wall] is the wall-clock time as entered; it's
  /// resolved to a UTC instant using the target's [timezone].
  Future<void> createItem({
    required String targetUid,
    required String createdByUid,
    required String groupId,
    required String title,
    String? note,
    required DateTime wall,
    required String timezone,
  }) async {
    final instant = resolveWallTimeToUtc(wall, timezone);
    await _items(targetUid).add({
      'targetUid': targetUid,
      'createdByUid': createdByUid,
      'groupId': groupId,
      'title': title.trim(),
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      'localWallTime': formatWallTime(wall),
      'timezone': timezone,
      'scheduledInstantUtc': Timestamp.fromDate(instant),
      'status': ScheduleItemStatus.pending.name,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// All items belonging to a target (they filter by status in the UI).
  Stream<List<ScheduleItem>> watchItemsForTarget(String targetUid) {
    return _items(targetUid).snapshots().map(
          (s) => s.docs.map(ScheduleItem.fromDoc).toList(),
        );
  }

  /// All items a planner created, across targets — powers their activity view.
  Stream<List<ScheduleItem>> watchItemsByPlanner(String plannerUid) {
    return _db
        .collectionGroup('items')
        .where('createdByUid', isEqualTo: plannerUid)
        .snapshots()
        .map((s) => s.docs.map(ScheduleItem.fromDoc).toList());
  }

  // --- transitions ---

  Future<void> _setStatus(
    String targetUid,
    String itemId,
    ScheduleItemStatus status, {
    Map<String, dynamic> extra = const {},
  }) {
    return _items(targetUid).doc(itemId).set({
      'status': status.name,
      'updatedAt': FieldValue.serverTimestamp(),
      ...extra,
    }, SetOptions(merge: true));
  }

  Future<void> approve(String targetUid, String itemId) =>
      _setStatus(targetUid, itemId, ScheduleItemStatus.approved,
          extra: {'decidedAt': FieldValue.serverTimestamp()});

  Future<void> reject(String targetUid, String itemId, {String? reason}) =>
      _setStatus(targetUid, itemId, ScheduleItemStatus.rejected, extra: {
        'decidedAt': FieldValue.serverTimestamp(),
        if (reason != null && reason.trim().isNotEmpty)
          'rejectionReason': reason.trim(),
      });

  /// Target records completion — status stays `approved`, outcome is layered on.
  Future<void> markDone(String targetUid, String itemId) {
    return _items(targetUid).doc(itemId).set({
      'outcome': {
        'result': OutcomeResult.done.name,
        'completedAt': FieldValue.serverTimestamp(),
      },
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> markSkipped(String targetUid, String itemId, {String? reason}) {
    return _items(targetUid).doc(itemId).set({
      'outcome': {
        'result': OutcomeResult.skipped.name,
        'skippedAt': FieldValue.serverTimestamp(),
        if (reason != null && reason.trim().isNotEmpty) 'skipReason': reason.trim(),
      },
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
