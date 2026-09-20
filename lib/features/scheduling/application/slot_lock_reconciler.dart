import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/slot_lock_repository.dart';
import '../domain/schedule_item.dart';
import 'schedule_providers.dart';
import 'slot_availability.dart';

/// Removes legacy `scheduleSlots` locks from the item stream.
///
/// New items do not create locks: schedule entries are point alarms with no
/// duration, so several may share a half-hour. This reconciler remains wired
/// temporarily so existing installations self-clean the old blocker documents.
class SlotLockReconciler {
  SlotLockReconciler(this._repository);

  final SlotLockRepository _repository;

  /// Guards against two reconciles interleaving — the stream can emit again
  /// while the first pass is still awaiting its deletes, and they would race on
  /// the same lock documents.
  bool _running = false;

  /// Release every legacy lock implied by [items] for [targetUid].
  ///
  /// Idempotent, which is what makes it safe on every emission and at app start:
  /// a lock already gone reads as no owner and is skipped. Returns the slot
  /// indexes it actually released, so a test asserts the effect, not the calls.
  /// [now] is retained for call-site compatibility during the migration.
  Future<Set<int>> reconcile({
    required String targetUid,
    required List<ScheduleItem> items,
    DateTime? now,
  }) async {
    if (_running) return const <int>{};
    _running = true;
    try {
      final releasable =
          releasableSlotLocks(items, (now ?? DateTime.now()).toUtc());
      final released = <int>{};
      for (final entry in releasable.entries) {
        final owner =
            await _repository.lockOwner(targetUid: targetUid, slotIndex: entry.key);
        if (owner == null) continue; // no lock present — nothing to release
        // Delete only a lock owned by one of this slot's known items. An
        // unaccounted-for lock remains untouched.
        if (!entry.value.contains(owner)) continue;
        await _repository.release(targetUid: targetUid, slotIndex: entry.key);
        released.add(entry.key);
      }
      return released;
    } finally {
      _running = false;
    }
  }
}

final slotLockRepositoryProvider = Provider<SlotLockRepository>((ref) {
  return SlotLockRepository(FirebaseFirestore.instance);
});

final slotLockReconcilerProvider = Provider<SlotLockReconciler>((ref) {
  return SlotLockReconciler(ref.watch(slotLockRepositoryProvider));
});

/// Runs the reconcile on every emission of the target's RECORD stream.
///
/// The record, not the filtered view: a done item the user archived vanishes
/// from the view, and its leaked lock must still be cleaned. A `listen`, not a
/// widget — the locks must be maintained whether or not any schedule screen is
/// mounted, exactly like its three neighbours in `app.dart`.
final slotLockSyncProvider = Provider<void>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return;
  final reconciler = ref.watch(slotLockReconcilerProvider);

  ref.listen<AsyncValue<List<ScheduleItem>>>(
    allItemsAsTargetProvider,
    (_, next) {
      final items = next.value;
      if (items == null) return;
      // Best-effort: a failed reconcile leaves the current locks in place and
      // the next emission retries. It must never surface as a UI error — nobody
      // asked for this to happen.
      unawaited(reconciler
          .reconcile(targetUid: uid, items: items)
          .catchError((_) => <int>{}));
    },
    fireImmediately: true,
  );
});
