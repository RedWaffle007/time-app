import 'package:cloud_firestore/cloud_firestore.dart';

/// A unanimous request to add [candidateUid] to a group.
///
/// The document id is the candidate uid and lives at
/// `groups/{groupId}/joinRequests/{candidateUid}`. An invitation from a friend
/// and a request made with a code deliberately share this model: neither path
/// is allowed to bypass the current members' approval.
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
  bool hasApproved(String uid) => approvalUids.contains(uid);

  int get approvalsRequired => requiredApproverUids.length;
  int get approvalsReceived =>
      approvalUids.where(requiredApproverUids.contains).toSet().length;

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
