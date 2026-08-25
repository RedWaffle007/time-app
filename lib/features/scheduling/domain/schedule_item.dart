import 'package:cloud_firestore/cloud_firestore.dart';

/// Lifecycle status of a schedule item (see data-model.md state machine).
enum ScheduleItemStatus { pending, approved, rejected, cancelled, withdrawn }

enum OutcomeResult { done, skipped }

/// The outcome layered on top of an approved item. Kept separate from status so
/// approval and completion stay two distinct facts (the accountability signal).
class ScheduleOutcome {
  const ScheduleOutcome({
    required this.result,
    this.completedAt,
    this.skippedAt,
    this.skipReason,
  });

  final OutcomeResult result;
  final DateTime? completedAt;
  final DateTime? skippedAt;
  final String? skipReason;

  static ScheduleOutcome? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final result = m['result'] == 'skipped' ? OutcomeResult.skipped : OutcomeResult.done;
    return ScheduleOutcome(
      result: result,
      completedAt: (m['completedAt'] as Timestamp?)?.toDate(),
      skippedAt: (m['skippedAt'] as Timestamp?)?.toDate(),
      skipReason: m['skipReason'] as String?,
    );
  }
}

/// A timetable item a planner created for a target. Stored at
/// `scheduleItems/{targetUid}/items/{itemId}`.
class ScheduleItem {
  const ScheduleItem({
    required this.id,
    required this.targetUid,
    required this.createdByUid,
    required this.groupId,
    required this.title,
    required this.localWallTime,
    required this.timezone,
    required this.scheduledInstantUtc,
    required this.status,
    this.note,
    this.outcome,
    this.rejectionReason,
    this.createdAt,
    this.decidedAt,
  });

  final String id;
  final String targetUid;
  final String createdByUid;
  final String groupId;
  final String title;
  final String? note;

  /// Wall-clock the planner set, e.g. "2026-07-20T09:00" (no offset).
  final String localWallTime;

  /// IANA zone the item was built against (snapshot of target's home tz).
  final String timezone;

  /// Absolute instant = localWallTime resolved in timezone. Source of truth.
  final DateTime scheduledInstantUtc;

  final ScheduleItemStatus status;
  final ScheduleOutcome? outcome;
  final String? rejectionReason;
  final DateTime? createdAt;

  /// When the target decided (approved/rejected), or when a self-authored item
  /// was created already-approved. Written by `approve`/`reject`/self-create and
  /// permitted by the item rules' decision whitelist. The source for future
  /// response-latency stats (`decidedAt - createdAt`), which is why it is
  /// captured now: it cannot be reconstructed for a plan decided before the
  /// field existed. Null on a still-pending item and on planner-withdrawn items
  /// (a withdrawal is not a target decision; it carries `withdrawnAt` instead).
  final DateTime? decidedAt;

  // -------------------------------------------------------------------------
  // Archive eligibility (DECISIONS.md "Archive — the terminal-state split").
  //
  // Terminal is NOT one bucket. Two terminal states are clutter the instant
  // they occur, and two are not:
  //
  //   rejected / withdrawn  → AUTO-hidden on entry. Rejecting IS the clearing
  //                           action; a rejected row must never sit in the
  //                           Activity feed piling up.
  //   done / skipped        → MANUAL. These are not clutter the moment they
  //                           happen — you archive them when you're ready.
  //
  // Both are hide-only. The document is untouched in every case, so summaries,
  // stats and any future records generation still count the item — provided
  // they read the RECORD providers, not the filtered views. That constraint is
  // stated where it can be violated, in `schedule_providers.dart`.
  //
  // A LIVE item (`pending`, or `approved`-not-done) is never hideable by either
  // route. Hiding one would let you bury a plan you never responded to, which
  // is the accountability failure the whole design exists to prevent.
  // -------------------------------------------------------------------------

  /// Hidden from both parties' feeds automatically, the moment the status is
  /// set. **Not a stored flag — a pure view rule**, and necessarily so: the
  /// person who rejects is not the person whose feed is cluttered (a rejected
  /// item never appears in the target's own views at all; the pile-up is in the
  /// PLANNER's Activity feed). Clearing it by writing an archive entry would
  /// require the target to write into the planner's own subtree, destroying the
  /// property that makes this shape safe — nobody can affect anyone else's data.
  /// As a view rule it costs no write, cannot half-fail, and needs no rule.
  ///
  /// `cancelled` rides along as a dead state. No code path sets it today.
  bool get isAutoArchived =>
      status == ScheduleItemStatus.rejected ||
      status == ScheduleItemStatus.withdrawn ||
      status == ScheduleItemStatus.cancelled;

  /// Settled with a recorded outcome, so the user may archive it by hand. This
  /// is the only route that writes to `users/{uid}/state/archived`, and the only
  /// one that is reversible from the Archived screen — un-hiding a rejected row
  /// would just put the clutter back.
  bool get isManuallyArchivable => outcome != null;

  /// Nothing further will happen to this item.
  bool get isSettled => isAutoArchived || isManuallyArchivable;

  factory ScheduleItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return ScheduleItem(
      id: doc.id,
      targetUid: (d['targetUid'] ?? '') as String,
      createdByUid: (d['createdByUid'] ?? '') as String,
      groupId: (d['groupId'] ?? '') as String,
      title: (d['title'] ?? '') as String,
      note: d['note'] as String?,
      localWallTime: (d['localWallTime'] ?? '') as String,
      timezone: (d['timezone'] ?? '') as String,
      scheduledInstantUtc:
          (d['scheduledInstantUtc'] as Timestamp?)?.toDate() ?? DateTime.now().toUtc(),
      status: ScheduleItemStatus.values.firstWhere(
        (s) => s.name == d['status'],
        orElse: () => ScheduleItemStatus.pending,
      ),
      outcome: ScheduleOutcome.fromMap(d['outcome'] as Map<String, dynamic>?),
      rejectionReason: d['rejectionReason'] as String?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      decidedAt: (d['decidedAt'] as Timestamp?)?.toDate(),
    );
  }
}
