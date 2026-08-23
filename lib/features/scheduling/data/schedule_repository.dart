import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/timezone/tz_resolver.dart';
import '../domain/schedule_item.dart';
import '../domain/slot.dart';

/// Raised when the target's slot was claimed between the planner opening the
/// modal and submitting. Carries a message already written for the user, the
/// same contract as `ChatbotFailure`.
class SlotTakenException implements Exception {
  const SlotTakenException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Creates schedule items and drives their status/outcome transitions.
class ScheduleRepository {
  ScheduleRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _items(String targetUid) =>
      _db.collection('scheduleItems').doc(targetUid).collection('items');

  /// Creates an item. [wall] is the wall-clock time as entered; it's resolved to
  /// a UTC instant using the target's [timezone].
  ///
  /// Two callers:
  ///   • a planner planning for someone else — [groupId] names the granting
  ///     group and [status] stays `pending` (the target approves per item).
  ///   • a user planning for themselves — [groupId] is null (no group needed)
  ///     and [status] is `approved` (self-authored items skip the queue).
  /// The rules enforce that only the self path may create an `approved` item.
  /// Returns the new item's id so the caller can fire the `created` push
  /// (planner path only — self-planned items have no one to notify).
  Future<String> createItem({
    required String targetUid,
    required String createdByUid,
    String? groupId,
    required String title,
    String? note,
    required DateTime wall,
    required String timezone,
    ScheduleItemStatus status = ScheduleItemStatus.pending,
  }) async {
    final instant = resolveWallTimeToUtc(wall, timezone);

    // The item and its SLOT LOCK land in one batch, or neither does.
    //
    // This is the server-side conflict re-check, and it is the only one
    // available: there is no Cloud Function in this project, and rules cannot
    // run a query, so "does something already occupy this slot" cannot be asked
    // directly. What can be done is the `usernames/{handle}` device — a computed
    // id whose `create` fails when the document exists. `allow update: if false`
    // on the lock is what turns a `set` into a failure rather than an overwrite.
    //
    // So a slot taken while the planner's modal was open is rejected HERE, at
    // write time, however stale the UI was.
    final slot = slotIndexFor(instant);
    final itemRef = _items(targetUid).doc();
    final lockRef = _slotLock(targetUid, slot);

    final batch = _db.batch();
    batch.set(lockRef, {
      'targetUid': targetUid,
      'createdByUid': createdByUid,
      'itemId': itemRef.id,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(itemRef, {
      'targetUid': targetUid,
      'createdByUid': createdByUid,
      'groupId': groupId ?? '',
      'title': title.trim(),
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      'localWallTime': formatWallTime(wall),
      'timezone': timezone,
      'scheduledInstantUtc': Timestamp.fromDate(instant),
      'status': status.name,
      // A self-approved item is decided at creation — record it for parity with
      // the approve() transition.
      if (status == ScheduleItemStatus.approved)
        'decidedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    try {
      await batch.commit();
    } on FirebaseException catch (e) {
      // A denial here is ambiguous on its own — the lock branch and the item
      // branch both answer `permission-denied`. Re-reading the lock is what
      // separates "someone just took this slot" from a genuine authz failure,
      // and the difference is the whole point: one is the user's problem to
      // solve by picking another time, the other is not their problem at all.
      if (e.code == 'permission-denied' && await _slotIsTaken(lockRef)) {
        throw const SlotTakenException(
          'That time was just taken. Pick another slot.',
        );
      }
      rethrow;
    }
    return itemRef.id;
  }

  DocumentReference<Map<String, dynamic>> _slotLock(
    String targetUid,
    int slotIndex,
  ) =>
      _db
          .collection('scheduleSlots')
          .doc(targetUid)
          .collection('slots')
          .doc(slotLockId(slotIndex));

  Future<bool> _slotIsTaken(
    DocumentReference<Map<String, dynamic>> lockRef,
  ) async {
    try {
      return (await lockRef.get()).exists;
    } catch (_) {
      // Cannot tell — say no and let the original error surface unchanged.
      // Claiming "taken" on a failed read would send the planner hunting for a
      // free slot that was never the problem.
      return false;
    }
  }

  /// Free the slot a dead item was holding.
  ///
  /// Best-effort and deliberately NOT batched with the status write. A lock that
  /// outlives its item costs one falsely-blocked half-hour; a status write that
  /// failed because a lock delete failed would break the consent loop, which
  /// matters more.
  Future<void> _releaseSlot(String targetUid, ScheduleItem item) async {
    try {
      await _slotLock(targetUid, slotIndexFor(item.scheduledInstantUtc))
          .delete();
    } catch (_) {
      // Ignored on purpose — see above.
    }
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

  /// Planner withdraws a plan they created, BEFORE the target has decided on it
  /// (Group C). Only a `pending` item can be withdrawn; the field set here must
  /// match exactly what the withdraw branch of firestore.rules permits (status,
  /// withdrawnAt, updatedAt) — the planner is not the target, so this is the one
  /// item write a non-target is allowed, and it is tightly scoped.
  Future<void> withdraw(String targetUid, String itemId, {ScheduleItem? item}) async {
    await _items(targetUid).doc(itemId).set({
      'status': ScheduleItemStatus.withdrawn.name,
      'withdrawnAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    // A withdrawn plan is dead, so it must stop holding the target's slot.
    // Without this a retracted plan would block that half-hour forever.
    if (item != null) await _releaseSlot(targetUid, item);
  }

  Future<void> reject(
    String targetUid,
    String itemId, {
    String? reason,
    ScheduleItem? item,
  }) async {
    await _setStatus(targetUid, itemId, ScheduleItemStatus.rejected, extra: {
      'decidedAt': FieldValue.serverTimestamp(),
      if (reason != null && reason.trim().isNotEmpty)
        'rejectionReason': reason.trim(),
    });
    // Same reasoning as withdraw: a rejected plan has no claim on the slot.
    if (item != null) await _releaseSlot(targetUid, item);
  }

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
