import 'package:flutter_test/flutter_test.dart';

import 'package:time_app/features/scheduling/application/slot_lock_reconciler.dart';
import 'package:time_app/features/scheduling/data/slot_lock_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/domain/slot.dart';

/// The reconciler's orchestration: which locks it reads, which it deletes, and
/// that it never touches a lock it does not own. The rule it applies
/// (`releasableSlotLocks`) is proven separately in `slot_availability_test.dart`.

/// An in-memory stand-in for `scheduleSlots/{targetUid}/slots`. Records reads and
/// deletes so a test can assert the collision guard actually gates the delete —
/// not just that the final state is right.
class FakeSlotLockRepository implements SlotLockRepository {
  FakeSlotLockRepository(this._owners);

  /// slotIndex -> itemId the lock names. Absent key = no lock.
  final Map<int, String> _owners;

  final List<int> reads = [];
  final List<int> deletes = [];

  @override
  Future<String?> lockOwner({
    required String targetUid,
    required int slotIndex,
  }) async {
    reads.add(slotIndex);
    return _owners[slotIndex];
  }

  @override
  Future<void> release({
    required String targetUid,
    required int slotIndex,
  }) async {
    deletes.add(slotIndex);
    _owners.remove(slotIndex);
  }
}

ScheduleItem item({
  required String id,
  required DateTime instantUtc,
  ScheduleItemStatus status = ScheduleItemStatus.approved,
  ScheduleOutcome? outcome,
}) =>
    ScheduleItem(
      id: id,
      targetUid: 'B',
      createdByUid: 'A',
      groupId: 'g',
      title: 'x',
      localWallTime: '',
      timezone: 'Asia/Kolkata',
      scheduledInstantUtc: instantUtc,
      status: status,
      outcome: outcome,
    );

void main() {
  // A fixed clock injected into every reconcile so past/future is deterministic
  // (the reconciler otherwise reads the wall clock).
  final now = DateTime.utc(2026, 8, 25, 12, 0);
  final past10 = DateTime.utc(2026, 8, 25, 10, 30);
  final past11 = DateTime.utc(2026, 8, 25, 11, 30);
  final future = DateTime.utc(2026, 8, 25, 13, 30);
  final slot10 = slotIndexFor(past10);
  final slot11 = slotIndexFor(past11);

  test('releases the lock of a completed item', () async {
    final repo = FakeSlotLockRepository({slot10: 'a'});
    final released = await SlotLockReconciler(repo).reconcile(
      targetUid: 'B',
      now: now,
      items: [
        item(id: 'a', instantUtc: past10,
            outcome: const ScheduleOutcome(result: OutcomeResult.done)),
      ],
    );
    expect(released, {slot10});
    expect(repo.deletes, [slot10]);
    expect(repo.lockOwner(targetUid: 'B', slotIndex: slot10), completion(isNull));
  });

  test('releases a FIRED past approved item with no outcome — the alarm-dismiss '
      'regression', () async {
    // The bug that came back: dismissing the full-screen alarm leaves the item
    // approved / no outcome. It is live by status but its slot is past, so its
    // lock must go — status-only keying stranded it forever.
    final repo = FakeSlotLockRepository({slot10: 'a'});
    final released = await SlotLockReconciler(repo).reconcile(
      targetUid: 'B',
      now: now,
      items: [item(id: 'a', instantUtc: past10)], // approved, no outcome, past
    );
    expect(released, {slot10});
    expect(repo.deletes, [slot10]);
  });

  test('leaves a live FUTURE item’s lock alone — no read, no delete', () async {
    final repo = FakeSlotLockRepository({slotIndexFor(future): 'a'});
    final released = await SlotLockReconciler(repo).reconcile(
      targetUid: 'B',
      now: now,
      items: [item(id: 'a', instantUtc: future)], // approved, future
    );
    expect(released, isEmpty);
    expect(repo.deletes, isEmpty);
    expect(repo.reads, isEmpty, reason: 'a live future slot is never probed');
  });

  test('is idempotent — a second pass with the lock gone deletes nothing',
      () async {
    final repo = FakeSlotLockRepository({slot10: 'a'});
    final reconciler = SlotLockReconciler(repo);
    final items = [
      item(id: 'a', instantUtc: past10,
          outcome: const ScheduleOutcome(result: OutcomeResult.done)),
    ];
    await reconciler.reconcile(targetUid: 'B', now: now, items: items);
    final second =
        await reconciler.reconcile(targetUid: 'B', now: now, items: items);
    expect(second, isEmpty);
    expect(repo.deletes, [slot10], reason: 'deleted once, not twice');
  });

  test('collision guard — a live FUTURE item protects a shared lock', () async {
    // Two items in one FUTURE slot, the live one owns the lock. The dead item
    // must not free it: the live future item keeps the slot, excluded before any
    // read.
    final repo = FakeSlotLockRepository({slotIndexFor(future): 'live'});
    final released = await SlotLockReconciler(repo).reconcile(
      targetUid: 'B',
      now: now,
      items: [
        item(id: 'dead', instantUtc: future, status: ScheduleItemStatus.rejected),
        item(id: 'live', instantUtc: future.add(const Duration(minutes: 15))),
      ],
    );
    expect(released, isEmpty);
    expect(repo.deletes, isEmpty);
  });

  test('a lock naming an id not in the stream is left untouched', () async {
    // Past slot, so it is a candidate: read the owner, see it matches no item we
    // found, and refuse to delete something we cannot account for.
    final repo = FakeSlotLockRepository({slot10: 'stranger'});
    final released = await SlotLockReconciler(repo).reconcile(
      targetUid: 'B',
      now: now,
      items: [
        item(id: 'dead', instantUtc: past10, status: ScheduleItemStatus.rejected),
      ],
    );
    expect(released, isEmpty);
    expect(repo.reads, [slot10]);
    expect(repo.deletes, isEmpty);
  });

  test('cleans several leaked locks in one pass', () async {
    final repo = FakeSlotLockRepository({slot10: 'a', slot11: 'b'});
    final released = await SlotLockReconciler(repo).reconcile(
      targetUid: 'B',
      now: now,
      items: [
        item(id: 'a', instantUtc: past10, status: ScheduleItemStatus.withdrawn),
        item(id: 'b', instantUtc: past11,
            outcome: const ScheduleOutcome(result: OutcomeResult.skipped)),
      ],
    );
    expect(released, {slot10, slot11});
    expect(repo.deletes..sort(), [slot10, slot11]..sort());
  });
}
