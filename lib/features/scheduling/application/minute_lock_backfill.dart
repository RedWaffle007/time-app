import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../domain/schedule_item.dart';
import '../domain/slot.dart';
import 'schedule_providers.dart';

/// My live plans still ahead — the ones that must hold their minute (Batch G
/// item 4). Uses [blocksSlot], the one definition of "live".
List<ScheduleItem> itemsNeedingMinuteLock(
  Iterable<ScheduleItem> items,
  DateTime nowUtc,
) => [
  for (final item in items)
    if (blocksSlot(item) && item.scheduledInstantUtc.toUtc().isAfter(nowUtc))
      item,
];

/// Locks the minutes of plans made before minute locks existed (item 4), so
/// they block a clash like every new plan does. **Driven off the item stream,
/// never off transitions** — the same doctrine as every other reconciler here.
/// Runs on the TARGET's device: the rules let the target lock the minute of any
/// of their own live plans, over a free lock or one whose plan is dead.
///
/// A minute already held by ANOTHER live plan (two older plans at one minute)
/// is left alone — neither is dropped; the clash simply predates the rule.
/// Best-effort: a failure is retried on the next emission.
class MinuteLockBackfill {
  MinuteLockBackfill({required this.holderOf, required this.claim});

  /// The item id holding my minute at the instant, or null when free.
  final Future<String?> Function(DateTime instantUtc) holderOf;
  final Future<void> Function(String itemId, DateTime instantUtc) claim;

  final _settled = <String>{};
  bool _running = false;

  /// Returns the ids it locked, so a test can assert the diff.
  Future<Set<String>> run(List<ScheduleItem> items, DateTime nowUtc) async {
    final locked = <String>{};
    if (_running) return locked;
    _running = true;
    try {
      final live = itemsNeedingMinuteLock(items, nowUtc);
      final liveIds = {for (final i in live) i.id};
      for (final item in live) {
        if (_settled.contains(item.id)) continue;
        try {
          final holder = await holderOf(item.scheduledInstantUtc);
          final free = holder == null || !liveIds.contains(holder);
          if (holder != item.id && free) {
            await claim(item.id, item.scheduledInstantUtc);
            locked.add(item.id);
          }
          _settled.add(item.id);
        } catch (_) {
          // Retried on the next emission.
        }
      }
    } finally {
      _running = false;
    }
    return locked;
  }
}

final minuteLockBackfillProvider = Provider<MinuteLockBackfill?>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return null;
  final repository = ref.watch(scheduleRepositoryProvider);
  return MinuteLockBackfill(
    holderOf: (instant) => repository.minuteLockHolder(uid, instant),
    claim: (itemId, instant) => repository.claimMinuteLock(
      targetUid: uid,
      itemId: itemId,
      instantUtc: instant,
    ),
  );
});

/// The one wire, watched from `app.dart` beside the other reconcilers.
final minuteLockBackfillSyncProvider = Provider<void>((ref) {
  final backfill = ref.watch(minuteLockBackfillProvider);
  if (backfill == null) return;
  ref.listen<AsyncValue<List<ScheduleItem>>>(allItemsAsTargetProvider, (
    _,
    next,
  ) {
    final items = next.value;
    if (items == null) return;
    unawaited(backfill.run(items, DateTime.now().toUtc()));
  }, fireImmediately: true);
});
