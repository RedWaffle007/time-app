import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/schedule_repository.dart';
import '../domain/schedule_item.dart';
import 'item_lapse_policy.dart';
import 'schedule_providers.dart';

/// Auto-resolves unaddressed items at the end of their local day — the FIFTH
/// stream-driven reconciler, the same shape as reminders, stats, planner-access
/// and slot-locks: **driven off the item stream, never off transitions.**
///
/// ## What it closes
///
/// A pending plan the target never approves, or an approved item they never act
/// on, would otherwise sit in "next" indefinitely. One rule — [lapsedItems] —
/// applied to whatever the stream currently says resolves both at the item's
/// response deadline (`responseDeadlineUtc`: end of its own local day, or two
/// hours after its scheduled time if later): pending → `reject` ("Not approved in time"),
/// approved-with-no-outcome → conditional skip ("Did not respond"). Nothing
/// is deleted; the settled item stays visible to the accountability partner,
/// and its reason feeds stats. The conditional write prevents this generic
/// fallback from overwriting a more specific alarm-timeout outcome.
///
/// ## Doctrine
///
/// It runs on the TARGET's own device (`allItemsAsTargetProvider` is the
/// signed-in user's items as target), which is the only party the rules let make
/// these writes. Like its neighbours it is client-driven: an item lapses on the
/// next stream emission or app open after its local midnight, not by a server
/// job — there are no Cloud Functions in this project. That is enough for the
/// real case (yesterday's items clearing when the app is next used) and matches
/// every other reconciler here.
///
/// **Do not add a per-transition auto-resolve hook.** One place decides.
class ItemLapseReconciler {
  ItemLapseReconciler(this._repository);

  final ScheduleRepository _repository;

  /// Guards against two passes interleaving: the stream can emit again while the
  /// first pass is still awaiting its writes, and the second would re-select the
  /// same not-yet-propagated items.
  bool _running = false;

  /// Apply every lapse [items] imply for [targetUid] as of [now] (default: the
  /// real clock). Idempotent — a settled item is never re-touched — so it is
  /// safe on every emission and at app start. Returns the counts actually
  /// written, so a test asserts the effect rather than the calls.
  Future<({int approved, int skipped})> reconcile({
    required String targetUid,
    required List<ScheduleItem> items,
    DateTime? now,
  }) async {
    if (_running) return (approved: 0, skipped: 0);
    _running = true;
    try {
      final lapsed = lapsedItems(items, (now ?? DateTime.now()).toUtc());
      var approved = 0;
      var skipped = 0;
      // F2: a legacy pending plan becomes an alarm (the reminder reconciler
      // arms it off the next emission) …
      for (final item in lapsed.toApprove) {
        await _repository.approve(targetUid, item.id);
        approved++;
      }
      // … or, already past its deadline, is settled as skipped.
      for (final item in lapsed.toApproveAndSkip) {
        await _repository.approve(targetUid, item.id);
        approved++;
        final recorded = await _repository.markSkippedIfUnsettled(
          targetUid,
          item.id,
          reason: kLapsedSkipReason,
        );
        if (recorded) skipped++;
      }
      for (final item in lapsed.toSkip) {
        final recorded = await _repository.markSkippedIfUnsettled(
          targetUid,
          item.id,
          reason: kLapsedSkipReason,
        );
        if (recorded) skipped++;
      }
      return (approved: approved, skipped: skipped);
    } finally {
      _running = false;
    }
  }
}

final itemLapseReconcilerProvider = Provider<ItemLapseReconciler>((ref) {
  return ItemLapseReconciler(ref.watch(scheduleRepositoryProvider));
});

/// Runs the lapse pass on every emission of the target's RECORD stream.
///
/// A `listen`, not a widget: unaddressed items must resolve whether or not any
/// schedule screen is mounted, exactly like its four neighbours in `app.dart`.
/// Best-effort — a failed write leaves the item as-is and the next emission
/// retries; it must never surface as a UI error.
final itemLapseSyncProvider = Provider<void>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return;
  final reconciler = ref.watch(itemLapseReconcilerProvider);

  ref.listen<AsyncValue<List<ScheduleItem>>>(allItemsAsTargetProvider, (
    _,
    next,
  ) {
    final items = next.value;
    if (items == null) return;
    unawaited(
      reconciler
          .reconcile(targetUid: uid, items: items)
          .catchError((_) => (approved: 0, skipped: 0)),
    );
  }, fireImmediately: true);
});
