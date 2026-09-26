import 'dart:async';

import '../../notifications/application/outcome_notifier.dart';
import '../data/alarm_timeline_repository.dart';

/// Tells the planner when the target dismisses a ringing alarm.
///
/// **The one place a dismissal becomes a push.** Both dismiss paths — the
/// full-screen AlarmScreen and the native lifecycle row replayed by the missed-
/// alarm service — record through [AlarmTimelineRepository.recordDismissed],
/// so wrapping that single call covers both without a second hook anywhere.
///
/// The push follows the WRITE, never replaces it: it is sent only after
/// `alarm.dismissedAt` is durable, because the Worker re-reads that field and
/// refuses (`not-dismissed`) without it. Fire-and-forget; the Worker's
/// `notifiedDismissed` stamp makes a repeat (an earlier-timestamp backfill, a
/// retried native row) a no-op, and self-plans are dropped server-side.
class DismissNotifyingTimelineRepository implements AlarmTimelineRepository {
  DismissNotifyingTimelineRepository(this._inner, this._notifier);

  final AlarmTimelineRepository _inner;
  final NotificationEventNotifier _notifier;

  @override
  Future<void> recordDismissed(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) async {
    await _inner.recordDismissed(targetUid, itemId, atUtc);
    unawaited(
      _notifier.notify(
        event: NotifyEvent.dismissed,
        targetUid: targetUid,
        itemId: itemId,
      ),
    );
  }

  @override
  Future<void> recordRang(String targetUid, String itemId, DateTime atUtc) =>
      _inner.recordRang(targetUid, itemId, atUtc);

  @override
  Future<void> recordUnavailable(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) => _inner.recordUnavailable(targetUid, itemId, atUtc);
}
