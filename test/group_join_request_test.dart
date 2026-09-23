import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/groups/domain/group_join_request.dart';

void main() {
  group('GroupJoinRequest', () {
    test(
      'counts only approvals that belong to the required voter snapshot',
      () {
        const request = GroupJoinRequest(
          candidateUid: 'candidate',
          candidateName: 'Candidate',
          requestedByUid: 'inviter',
          source: 'friend',
          status: 'pending',
          requiredApproverUids: ['member-a', 'member-b'],
          approvalUids: ['member-a', 'departed-member', 'member-a'],
        );

        expect(request.approvalsRequired, 2);
        expect(request.approvalsReceived, 1);
        expect(request.hasApproved('member-a'), isTrue);
        expect(request.hasApproved('member-b'), isFalse);
      },
    );

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
