import 'package:cloud_firestore/cloud_firestore.dart';

/// A request to add [candidateUid] to a group, decided by ANY ONE admin
/// (WhatsApp-style, Batch G item 3, 2026-09-27).
///
/// The document id is the candidate uid and lives at
/// `groups/{groupId}/joinRequests/{candidateUid}`. [source] is `code` (the
/// candidate entered the invite code), `friend` (a non-admin member invited a
/// friend) or `admin` (an admin added a friend directly — born approved).
/// [requiredApproverUids] is kept only for the retired unanimous flow's shape.
class GroupJoinRequest {
  const GroupJoinRequest({
    required this.candidateUid,
    required this.candidateName,
    required this.requestedByUid,
    required this.source,
    required this.status,
    required this.requiredApproverUids,
    required this.approvalUids,
    this.rejectionUid,
  });

  final String candidateUid;
  final String candidateName;
  final String requestedByUid;
  final String source;
  final String status;
  final List<String> requiredApproverUids;
  final List<String> approvalUids;
  final String? rejectionUid;

  bool get isPending => status == 'pending';

  /// Whether a member invited them (rather than the candidate using a code).
  bool get isInvitation => source == 'friend' && requestedByUid != candidateUid;

  factory GroupJoinRequest.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return GroupJoinRequest(
      candidateUid: (data['candidateUid'] ?? doc.id) as String,
      candidateName: (data['candidateName'] ?? '') as String,
      requestedByUid: (data['requestedByUid'] ?? '') as String,
      source: (data['source'] ?? '') as String,
      status: (data['status'] ?? '') as String,
      requiredApproverUids: List<String>.from(
        data['requiredApproverUids'] ?? const [],
      ),
      approvalUids: List<String>.from(data['approvalUids'] ?? const []),
      rejectionUid: data['rejectionUid'] as String?,
    );
  }
}
