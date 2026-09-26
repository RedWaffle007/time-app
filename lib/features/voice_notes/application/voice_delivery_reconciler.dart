import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import 'voice_delivery_policy.dart';
import 'voice_note_cache.dart';

/// Keeps a verified copy of every upcoming voice-note alarm on the TARGET's
/// phone, stamps the delivery receipt the planner sees, and deletes copies no
/// longer needed (item 32c). The sixth stream-driven reconciler: one rule
/// ([planVoiceDelivery]) over the item stream, re-run on resume and when the
/// Worker's rescue push asks. **No per-transition hook anywhere.**
class VoiceDeliveryReconciler {
  VoiceDeliveryReconciler(this._cache, this._markDelivered);

  final VoiceNoteCache _cache;
  final Future<void> Function(ScheduleItem item) _markDelivered;

  bool _running = false;
  bool _again = false;
  List<ScheduleItem> _lastItems = const [];
  String? _lastUid;

  /// Re-run on the last known items (resume, rescue push).
  Future<void> resync() => reconcile(uid: _lastUid, items: _lastItems);

  Future<({int fetched, int receipts, int pruned})> reconcile({
    required String? uid,
    required List<ScheduleItem> items,
    DateTime? now,
  }) async {
    _lastUid = uid;
    _lastItems = items;
    if (uid == null) return (fetched: 0, receipts: 0, pruned: 0);
    if (_running) {
      _again = true; // one follow-up pass with the newest items
      return (fetched: 0, receipts: 0, pruned: 0);
    }
    _running = true;
    var fetched = 0;
    var receipts = 0;
    var pruned = 0;
    try {
      final plan = planVoiceDelivery(items, uid, now ?? DateTime.now().toUtc());
      final needsReceipt = {for (final i in plan.receipt) i.id};
      for (final item in plan.fetch) {
        try {
          if (!await _cache.hasVerified(item)) {
            await _cache.ensure(item);
            fetched++;
          }
          if (needsReceipt.contains(item.id)) {
            await _markDelivered(item);
            receipts++;
          }
        } catch (e) {
          // Offline, or not ready yet: the next emission, resume or rescue
          // push retries. Never surfaces as a UI error.
          debugPrint('VoiceDelivery: ${item.id} not yet delivered: $e');
        }
      }
      try {
        pruned = await _cache.prune(plan.keepIds);
      } catch (_) {}
    } finally {
      _running = false;
    }
    if (_again) {
      _again = false;
      unawaited(resync());
    }
    return (fetched: fetched, receipts: receipts, pruned: pruned);
  }
}

final voiceDeliveryReconcilerProvider = Provider<VoiceDeliveryReconciler>((
  ref,
) {
  final repository = ref.watch(scheduleRepositoryProvider);
  return VoiceDeliveryReconciler(
    ref.watch(voiceNoteCacheProvider),
    (item) => repository.markVoiceNoteDelivered(item.targetUid, item.id),
  );
});

/// The one wire, watched in app.dart beside the other reconcilers.
final voiceDeliverySyncProvider = Provider<void>((ref) {
  final uid = ref.watch(currentUidProvider);
  final reconciler = ref.watch(voiceDeliveryReconcilerProvider);
  ref.listen<AsyncValue<List<ScheduleItem>>>(allItemsAsTargetProvider, (
    _,
    next,
  ) {
    final items = next.value;
    if (items == null) return;
    unawaited(reconciler.reconcile(uid: uid, items: items));
  }, fireImmediately: true);
});
