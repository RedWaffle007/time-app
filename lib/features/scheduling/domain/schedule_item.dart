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
    );
  }
}
