import 'dart:async';

import '../../notifications/application/outcome_notifier.dart';
import '../data/alarm_timeline_repository.dart';

/// Tells the planner when the target dismisses a ringing alarm — or when it
/// stopped unanswered (item 6).
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

  /// Events already reported from this process. Several paths report the
  /// same dismissal (the alarm screen, then the replayed native row), and
  /// each used to POST; the Worker's atomic claim now guarantees one push,
  /// this just stops the redundant calls (2026-09-27 device fix).
  final _reported = <String>{};

  void _notifyOnce(NotifyEvent event, String targetUid, String itemId) {
    final key = '${event.name}:$targetUid:$itemId';
    if (!_reported.add(key)) return;
    unawaited(() async {
      final result = await _notifier.notifyConfirmed(
        event: event,
        targetUid: targetUid,
        itemId: itemId,
      );
      // The call never reached the Worker: let a later report try again.
      if (result.reason.startsWith('transport-error')) _reported.remove(key);
    }());
  }

  @override
  Future<void> recordDismissed(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) async {
    await _inner.recordDismissed(targetUid, itemId, atUtc);
    _notifyOnce(NotifyEvent.dismissed, targetUid, itemId);
  }

  @override
  Future<void> recordRang(String targetUid, String itemId, DateTime atUtc) =>
      _inner.recordRang(targetUid, itemId, atUtc);

  /// Item 6 (2026-09-27): the alarm auto-stopped unanswered — tell the
  /// planner, the same way, only after `alarm.unavailableAt` is durable. The
  /// Worker's `notifiedUnavailable` stamp makes a replayed row a no-op.
  @override
  Future<void> recordUnavailable(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) async {
    await _inner.recordUnavailable(targetUid, itemId, atUtc);
    _notifyOnce(NotifyEvent.unavailable, targetUid, itemId);
  }
}
