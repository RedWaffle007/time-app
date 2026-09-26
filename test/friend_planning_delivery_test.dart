import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/groups/domain/planner_grant.dart';
import 'package:time_app/features/notifications/data/http_event_notifier.dart';
import 'package:time_app/features/scheduling/application/planning_target_picker.dart';

void main() {
  PlannerGrant grant(String target, String group) => PlannerGrant(
    plannerUid: 'me',
    targetUid: target,
    groupId: group,
    granted: true,
  );

  group('planning target picker', () {
    test('group permission control is shown only for non-friend members', () {
      expect(
        groupPlanningPermissionApplies('friend', friendUids: {'friend'}),
        isFalse,
      );
      expect(
        groupPlanningPermissionApplies('stranger', friendUids: {'friend'}),
        isTrue,
      );
    });

    test('every friend is a target, with no grant at all', () {
      final targets = effectivePlanningTargets(
        const [],
        friendUids: {'friend-a', 'friend-b'},
        plannerUid: 'me',
      );

      expect(
        {for (final t in targets) t.targetUid: t.groupId},
        {'friend-a': '', 'friend-b': ''},
      );
      expect(targets.every((t) => t.granted && t.plannerUid == 'me'), isTrue);
    });

    test('shows a friend only once across leftover and group grants', () {
      final targets = effectivePlanningTargets(
        [
          grant('friend', 'group-a'),
          grant('friend', ''),
          grant('friend', 'group-b'),
        ],
        friendUids: {'friend'},
        plannerUid: 'me',
      );

      expect(targets, hasLength(1));
      expect(targets.single.targetUid, 'friend');
      expect(targets.single.groupId, isEmpty);
    });

    test('a leftover revoked friendship grant does not remove a friend', () {
      final targets = effectivePlanningTargets(
        const [
          PlannerGrant(
            plannerUid: 'me',
            targetUid: 'friend',
            groupId: '',
            granted: false,
          ),
        ],
        friendUids: {'friend'},
        plannerUid: 'me',
      );

      expect(targets.map((g) => g.targetUid), ['friend']);
    });

    test('a non-friend needs a live GROUP grant; a leftover friendship grant '
        'adds nobody', () {
      final targets = effectivePlanningTargets(
        [
          grant('stranger', ''),
          grant('member', 'group-a'),
          const PlannerGrant(
            plannerUid: 'me',
            targetUid: 'revoked',
            groupId: 'group-a',
            granted: false,
          ),
        ],
        friendUids: const {},
        plannerUid: 'me',
      );

      expect(
        {for (final t in targets) t.targetUid: t.groupId},
        {'member': 'group-a'},
      );
    });

    test('never lists yourself', () {
      final targets = effectivePlanningTargets(
        const [],
        friendUids: {'me', 'friend'},
        plannerUid: 'me',
      );
      expect(targets.map((g) => g.targetUid), ['friend']);
    });
  });

  group('Worker delivery response', () {
    test('requires at least one actual FCM send', () {
      expect(
        notificationDeliveryFromWorkerResponse(
          statusCode: 200,
          body: '{"sent":1,"reason":"sent"}',
        ).delivered,
        isTrue,
      );
      final missingToken = notificationDeliveryFromWorkerResponse(
        statusCode: 200,
        body: '{"sent":0,"reason":"no-tokens"}',
      );
      expect(missingToken.delivered, isFalse);
      expect(missingToken.reason, 'no-tokens');
    });

    test('rejects HTTP errors and malformed success bodies', () {
      expect(
        notificationDeliveryFromWorkerResponse(
          statusCode: 500,
          body: '{}',
        ).reason,
        'worker-http-500',
      );
      expect(
        notificationDeliveryFromWorkerResponse(
          statusCode: 200,
          body: 'not-json',
        ).reason,
        'invalid-worker-response',
      );
    });
  });
}
