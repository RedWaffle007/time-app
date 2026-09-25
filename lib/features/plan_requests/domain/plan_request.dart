import 'package:cloud_firestore/cloud_firestore.dart';

/// A request to create actual schedule items for the requester.
///
/// This is deliberately unrelated to `PlanningRequest`, which asks for a
/// durable planning grant. A [PlanRequest] never grants authority: fulfilling
/// one still requires an active friendship and normal planning grant.
enum PlanRequestMode { onePlan, flexibleWindow }

enum PlanRequestStatus { pending, inProgress, fulfilled, declined, cancelled }

class RequestedPlanSpan {
  const RequestedPlanSpan({
    required this.itemId,
    required this.startUtc,
    required this.durationMinutes,
  });

  final String itemId;
  final DateTime startUtc;
  final int durationMinutes;

  DateTime get endUtc => startUtc.add(Duration(minutes: durationMinutes));

  Map<String, Object> toMap() => {
    'itemId': itemId,
    'startUtc': Timestamp.fromDate(startUtc.toUtc()),
    'durationMinutes': durationMinutes,
  };

  factory RequestedPlanSpan.fromMap(Map<String, dynamic> map) {
    return RequestedPlanSpan(
      itemId: map['itemId'] as String? ?? '',
      startUtc: (map['startUtc'] as Timestamp).toDate().toUtc(),
      durationMinutes: (map['durationMinutes'] as num?)?.toInt() ?? 0,
    );
  }
}

class PlanRequest {
  const PlanRequest({
    required this.id,
    required this.batchId,
    required this.requesterUid,
    required this.plannerUid,
    required this.mode,
    required this.status,
    required this.timezone,
    required this.windowStartUtc,
    required this.windowEndUtc,
    required this.durationMinutes,
    this.title,
    this.message,
    this.fulfilledSpans = const [],
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String batchId;
  final String requesterUid;
  final String plannerUid;
  final PlanRequestMode mode;
  final PlanRequestStatus status;
  final String timezone;
  final DateTime windowStartUtc;
  final DateTime windowEndUtc;
  final int durationMinutes;
  final String? title;
  final String? message;
  final List<RequestedPlanSpan> fulfilledSpans;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isOpen =>
      status == PlanRequestStatus.pending ||
      status == PlanRequestStatus.inProgress;

  bool get isOnePlan => mode == PlanRequestMode.onePlan;

  /// Deterministic per-recipient id makes retrying a multi-friend batch safe.
  static String requestId(String batchId, String plannerUid) =>
      '${batchId}_$plannerUid';

  factory PlanRequest.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return PlanRequest(
      id: doc.id,
      batchId: data['batchId'] as String? ?? '',
      requesterUid: data['requesterUid'] as String? ?? '',
      plannerUid: data['plannerUid'] as String? ?? '',
      mode: data['mode'] == 'flexibleWindow'
          ? PlanRequestMode.flexibleWindow
          : PlanRequestMode.onePlan,
      status: PlanRequestStatus.values.firstWhere(
        (value) => value.name == data['status'],
        orElse: () => PlanRequestStatus.pending,
      ),
      timezone: data['timezone'] as String? ?? '',
      windowStartUtc: (data['windowStartUtc'] as Timestamp).toDate().toUtc(),
      windowEndUtc: (data['windowEndUtc'] as Timestamp).toDate().toUtc(),
      durationMinutes: (data['durationMinutes'] as num?)?.toInt() ?? 0,
      title: data['title'] as String?,
      message: data['message'] as String?,
      fulfilledSpans: [
        for (final raw in data['fulfilledSpans'] as List<dynamic>? ?? const [])
          RequestedPlanSpan.fromMap(Map<String, dynamic>.from(raw as Map)),
      ],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// Half-open interval policy: adjacency is allowed; overlap is not.
///
/// A zero-duration legacy item is treated as an instant. It conflicts only
/// when it lands inside the new span (including exactly at its start), keeping
/// old point alarms readable without inventing a historical duration.
bool planSpansOverlap({
  required DateTime aStart,
  required int aMinutes,
  required DateTime bStart,
  required int bMinutes,
}) {
  final a = aStart.toUtc();
  final b = bStart.toUtc();
  if (aMinutes == 0 && bMinutes == 0) return a == b;
  if (aMinutes == 0) {
    final bEnd = b.add(Duration(minutes: bMinutes));
    return !a.isBefore(b) && a.isBefore(bEnd);
  }
  if (bMinutes == 0) {
    final aEnd = a.add(Duration(minutes: aMinutes));
    return !b.isBefore(a) && b.isBefore(aEnd);
  }
  final aEnd = a.add(Duration(minutes: aMinutes));
  final bEnd = b.add(Duration(minutes: bMinutes));
  return a.isBefore(bEnd) && b.isBefore(aEnd);
}

bool spanFitsPlanRequest(
  PlanRequest request, {
  required DateTime startUtc,
  required int durationMinutes,
}) {
  if (!request.isOpen || durationMinutes <= 0) return false;
  if (request.isOnePlan && durationMinutes != request.durationMinutes) {
    return false;
  }
  final start = startUtc.toUtc();
  final end = start.add(Duration(minutes: durationMinutes));
  if (start.isBefore(request.windowStartUtc) ||
      end.isAfter(request.windowEndUtc)) {
    return false;
  }
  // Fulfilled spans are append-only and chronological. Besides making the
  // planner flow predictable, this lets Firestore rules prove adjacency /
  // non-overlap without an unbounded loop over attacker-controlled maps.
  if (request.fulfilledSpans.isNotEmpty &&
      start.isBefore(request.fulfilledSpans.last.endUtc)) {
    return false;
  }
  return request.fulfilledSpans.every(
    (span) => !planSpansOverlap(
      aStart: start,
      aMinutes: durationMinutes,
      bStart: span.startUtc,
      bMinutes: span.durationMinutes,
    ),
  );
}
