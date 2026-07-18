import 'package:cloud_firestore/cloud_firestore.dart';

/// A directed consent: [plannerUid] may build [targetUid]'s schedule.
/// Stored at `groups/{groupId}/plannerGrants/{plannerUid}_{targetUid}`.
///
/// Consent is given BY the target (grantedByUid must be targetUid) — the app is
/// consent-first, not coercive.
class PlannerGrant {
  const PlannerGrant({
    required this.plannerUid,
    required this.targetUid,
    required this.groupId,
    required this.granted,
  });

  final String plannerUid;
  final String targetUid;
  final String groupId;
  final bool granted;

  /// Deterministic doc id so a grant is idempotent (one per planner→target pair).
  static String docId(String plannerUid, String targetUid) =>
      '${plannerUid}_$targetUid';

  factory PlannerGrant.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return PlannerGrant(
      plannerUid: (d['plannerUid'] ?? '') as String,
      targetUid: (d['targetUid'] ?? '') as String,
      groupId: (d['groupId'] ?? '') as String,
      granted: (d['granted'] ?? false) as bool,
    );
  }
}
