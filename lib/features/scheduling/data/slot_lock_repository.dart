import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/slot.dart';

/// The `scheduleSlots/{targetUid}/slots/{slotIndex}` lock collection, from the
/// reconciler's side of it.
///
/// The lock is WRITTEN in `ScheduleRepository.createItem`'s batch — that stays
/// the only writer, because the lock and the item it guards must land together
/// or not at all. This repository owns the two operations the self-healing
/// reconciler needs and nothing else: read who a lock names, and release it.
///
/// The path is derived from `slotLockId` (domain), the same id both this side
/// and the batch compute, so the two never drift.
class SlotLockRepository {
  SlotLockRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _slots(String targetUid) =>
      _db.collection('scheduleSlots').doc(targetUid).collection('slots');

  /// The `itemId` the lock at [slotIndex] names, or null when no lock is there.
  ///
  /// The reconciler compares it against the dead items it believes own the slot
  /// before deleting — the collision guard, so a lock belonging to a live item
  /// sharing the slot (legacy data) is left alone.
  Future<String?> lockOwner({
    required String targetUid,
    required int slotIndex,
  }) async {
    final snap = await _slots(targetUid).doc(slotLockId(slotIndex)).get();
    if (!snap.exists) return null;
    return (snap.data()?['itemId'] as String?) ?? '';
  }

  /// Delete the lock at [slotIndex]. Idempotent — deleting an absent lock is a
  /// no-op, which is what lets the reconcile run on every emission. The rules
  /// permit this because the caller is the target (they may delete any lock on
  /// their own schedule).
  Future<void> release({
    required String targetUid,
    required int slotIndex,
  }) {
    return _slots(targetUid).doc(slotLockId(slotIndex)).delete();
  }
}
