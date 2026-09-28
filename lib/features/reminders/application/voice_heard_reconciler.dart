import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/data/schedule_repository.dart';
import '../../scheduling/domain/schedule_item.dart';

/// Voice notes that were dismissed while ringing and are not closed yet
/// (2026-09-28, DECISIONS.md "Voice notes without Done/Skip"): dismissing a
/// voice note IS hearing it, so it closes as Done, shown "Heard". Pure.
List<ScheduleItem> voiceNotesHeardByDismiss(
  List<ScheduleItem> items,
  String uid,
) => [
  for (final item in items)
    if (item.targetUid == uid &&
        item.isVoiceAlarm &&
        item.status == ScheduleItemStatus.approved &&
        item.outcome == null &&
        item.alarm?.dismissedAt != null)
      item,
];

/// Closes them — **off the item stream, never off the dismiss transition**,
/// the same shape as the other reconcilers in `app.dart`. The dismiss itself
/// (alarm screen or the native row) records `alarm.dismissedAt` and sends the
/// planner "{Y} heard your voice note."; this only writes the outcome, so no
/// second push. First-write-wins (`markDone` refuses a settled item), so a
/// replay or another device is harmless.
class VoiceHeardReconciler {
  VoiceHeardReconciler(this._repository);

  final ScheduleRepository _repository;
  final _inFlight = <String>{};

  Future<int> reconcile(String uid, List<ScheduleItem> items) async {
    var closed = 0;
    for (final item in voiceNotesHeardByDismiss(items, uid)) {
      if (!_inFlight.add(item.id)) continue;
      try {
        if (await _repository.markDone(
          uid,
          item.id,
          plannerUid: item.createdByUid,
        )) {
          closed++;
        }
      } finally {
        _inFlight.remove(item.id);
      }
    }
    return closed;
  }
}

final voiceHeardReconcilerProvider = Provider<VoiceHeardReconciler>((ref) {
  return VoiceHeardReconciler(ref.watch(scheduleRepositoryProvider));
});

/// Runs on every emission of the target's RECORD stream. Best-effort: a
/// failed write retries on the next emission.
final voiceHeardSyncProvider = Provider<void>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return;
  final reconciler = ref.watch(voiceHeardReconcilerProvider);
  ref.listen<AsyncValue<List<ScheduleItem>>>(allItemsAsTargetProvider, (
    _,
    next,
  ) {
    final items = next.value;
    if (items == null) return;
    unawaited(reconciler.reconcile(uid, items).catchError((_) => 0));
  }, fireImmediately: true);
});
