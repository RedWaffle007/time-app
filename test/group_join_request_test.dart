import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/groups/domain/group_join_request.dart';

void main() {
  group('GroupJoinRequest', () {
    test('tells a member invitation from a code request', () {
      const invited = GroupJoinRequest(
        candidateUid: 'candidate',
        candidateName: 'Candidate',
        requestedByUid: 'inviter',
        source: 'friend',
        status: 'pending',
        requiredApproverUids: [],
        approvalUids: [],
      );
      const code = GroupJoinRequest(
        candidateUid: 'candidate',
        candidateName: 'Candidate',
        requestedByUid: 'candidate',
        source: 'code',
        status: 'pending',
        requiredApproverUids: [],
        approvalUids: [],
      );
      expect(invited.isInvitation, isTrue);
      expect(code.isInvitation, isFalse);
    });

    test('recognizes only the pending status as actionable', () {
      const pending = GroupJoinRequest(
        candidateUid: 'candidate',
        candidateName: 'Candidate',
        requestedByUid: 'candidate',
        source: 'code',
        status: 'pending',
        requiredApproverUids: [],
        approvalUids: [],
      );
      const rejected = GroupJoinRequest(
        candidateUid: 'candidate',
        candidateName: 'Candidate',
        requestedByUid: 'candidate',
        source: 'code',
        status: 'rejected',
        requiredApproverUids: [],
        approvalUids: [],
        rejectionUid: 'member-a',
      );

      expect(pending.isPending, isTrue);
      expect(rejected.isPending, isFalse);
    });
  });
}
