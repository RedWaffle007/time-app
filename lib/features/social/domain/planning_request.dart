import 'package:cloud_firestore/cloud_firestore.dart';

/// Which planning tier a request (or grant) is for.
///
///  * [normal] — the friend may PROPOSE plans; every item still hits the
///    target's per-item approval queue.
///  * [emergency] — reserved for #5: a plan the friend creates fires WITHOUT
///    per-item approval. A separate grant, requested/granted separately.
///
/// The kind is part of the request id, so a normal and an emergency request
/// between the same pair can be pending at once.
enum PlanningKind { normal, emergency }

/// Where a planning-permission request has got to. Mirrors the friend-request
/// lifecycle, but a settled request is DELETED (approve writes the grant then
/// removes the row; decline/withdraw just remove it), so only [pending] ever
/// persists — there is no stored `declined` record to re-ask around.
enum PlanningRequestStatus { pending, approved, declined, cancelled }

/// A request FROM one friend TO another for permission to plan for them.
/// Stored at `planningRequests/{fromUid}_{toUid}_{kind}`.
///
/// Distinct from a friend request (that is the friendship itself) and from the
/// per-item pending queue (that is approving one plan). Approval does not live
/// on this document — the target authors the friendship grant separately; this
/// row is only the ask.
class PlanningRequest {
  const PlanningRequest({
    required this.id,
    required this.fromUid,
    required this.toUid,
    required this.kind,
    required this.status,
  });

  final String id;
  final String fromUid;
  final String toUid;
  final PlanningKind kind;
  final PlanningRequestStatus status;

  /// The deterministic id. Must match the rules' `from + '_' + to + '_' + kind`.
  static String requestId({
    required String fromUid,
    required String toUid,
    required PlanningKind kind,
  }) =>
      '${fromUid}_${toUid}_${kind.name}';

  factory PlanningRequest.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return PlanningRequest(
      id: doc.id,
      fromUid: (d['fromUid'] ?? '') as String,
      toUid: (d['toUid'] ?? '') as String,
      kind: (d['kind'] == 'emergency')
          ? PlanningKind.emergency
          : PlanningKind.normal,
      status: PlanningRequestStatus.values.firstWhere(
        (s) => s.name == d['status'],
        orElse: () => PlanningRequestStatus.pending,
      ),
    );
  }
}
