import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/slot_lock_repository.dart';
import '../domain/schedule_item.dart';
import 'schedule_providers.dart';
import 'slot_availability.dart';

/// Keeps `scheduleSlots` in step with the item stream, **off the stream, never
/// off transitions** — the fourth wire of the same shape as reminders, stats and
/// planner-access.
///
/// ## The gap it closes
///
/// A slot lock is born in `createItem`'s batch and released in `withdraw()` /
/// `reject()`. Nothing releases it when an item is marked done or skipped, and a
/// release that fails while offline leaks one too. Each stale lock blocks a
/// half-hour the UI already shows as free — the UI reads the item stream
/// (`blocksSlot`), the write-race guard reads the lock, and the two drift.
///
/// ## The one design rule, and do not undo it
///
/// There is **no** `releaseSlot()` added to `markDone()` / `markSkipped()`. One
/// rule — *a lock should exist iff a live item sits in its slot* — is applied to
/// whatever the stream currently says. Done, skipped, an edit, a withdrawal:
/// none is a special case, because each simply stops producing a live item at
/// that slot. Adding a per-transition release would create a second place that
/// decides, and the two would disagree — and it would still not clean up the
/// locks that have already leaked. This does both.
///
/// It creates nothing: writing the lock stays inside `createItem`'s batch, so
/// the lock and its item are never split. This wire only DELETES stale locks.
class SlotLockReconciler {
  SlotLockReconciler(this._repository);

  final SlotLockRepository _repository;

  /// Guards against two reconciles interleaving — the stream can emit again
  /// while the first pass is still awaiting its deletes, and they would race on
  /// the same lock documents.
  bool _running = false;

  /// Release every stale lock implied by [items] for [targetUid].
  ///
  /// Idempotent, which is what makes it safe on every emission and at app start:
  /// a lock already gone reads as no owner and is skipped. Returns the slot
  /// indexes it actually released, so a test asserts the effect, not the calls.
  /// [now] defaults to the real clock; a test injects a fixed instant so the
  /// past/future split is deterministic.
  Future<Set<int>> reconcile({
    required String targetUid,
    required List<ScheduleItem> items,
    DateTime? now,
  }) async {
    if (_running) return const <int>{};
    _running = true;
    try {
      // `now` decides which slots are past (and so releasable) — read once, here,
      // so the whole pass sees one consistent clock.
      final releasable =
          releasableSlotLocks(items, (now ?? DateTime.now()).toUtc());
      final released = <int>{};
      for (final entry in releasable.entries) {
        final owner =
            await _repository.lockOwner(targetUid: targetUid, slotIndex: entry.key);
        if (owner == null) continue; // no lock present — nothing to release
        // Collision guard: the lock must name one of the dead items we found in
        // this slot. A lock naming anything else (a live item sharing the slot
        // in legacy data, or an id not in the stream) is left untouched.
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
