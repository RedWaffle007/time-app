import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/groups/domain/planner_grant.dart';
import 'package:time_app/features/notifications/data/http_event_notifier.dart';
import 'package:time_app/features/scheduling/application/planning_target_picker.dart';
import 'package:time_app/features/social/application/planning_permission_migrator.dart';

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

    test('shows a friend only once across friendship and group grants', () {
      final targets = effectivePlanningTargets(
        [
          grant('friend', 'group-a'),
          grant('friend', ''),
          grant('friend', 'group-b'),
        ],
        friendUids: {'friend'},
      );

      expect(targets, hasLength(1));
      expect(targets.single.targetUid, 'friend');
      expect(targets.single.groupId, isEmpty);
    });

    test('keeps distinct people and ignores revoked grants', () {
      final targets = effectivePlanningTargets([
        grant('friend-a', 'group-a'),
        grant('friend-b', 'group-a'),
        const PlannerGrant(
          plannerUid: 'me',
          targetUid: 'revoked',
          groupId: '',
          granted: false,
        ),
      ], friendUids: const {});

      expect(targets.map((g) => g.targetUid), ['friend-a', 'friend-b']);
    });

    test(
      'ignores group grants for friends and friendship grants for strangers',
      () {
        final targets = effectivePlanningTargets(
          [
            grant('friend', 'group-a'),
            grant('friend', ''),
            grant('stranger', ''),
            grant('stranger', 'group-a'),
          ],
          friendUids: {'friend'},
        );

        expect(
          {for (final target in targets) target.targetUid: target.groupId},
          {'friend': '', 'stranger': 'group-a'},
        );
      },
    );
  });

  group('group permission migration', () {
    test('moves only active group grants whose planners are now friends', () {
      final migrations = groupGrantsToMigrate(
        grantsOverTarget: [
          const PlannerGrant(
            plannerUid: 'friend',
            targetUid: 'me',
            groupId: 'group-a',
            granted: true,
          ),
          const PlannerGrant(
            plannerUid: 'stranger',
            targetUid: 'me',
            groupId: 'group-a',
            granted: true,
          ),
          const PlannerGrant(
            plannerUid: 'friend',
            targetUid: 'me',
            groupId: '',
            granted: true,
          ),
        ],
        friendUids: {'friend'},
      );

      expect(migrations, hasLength(1));
      expect(migrations.single.plannerUid, 'friend');
      expect(migrations.single.friendshipGrantAlreadyExists, isTrue);
    });

    test('writes the profile grant before revoking the group copy', () async {
      final actions = <String>[];
      await PlanningPermissionMigrator().migrate(
        grantsOverTarget: [
          const PlannerGrant(
            plannerUid: 'friend',
            targetUid: 'me',
            groupId: 'group-a',
            granted: true,
          ),
        ],
        friendUids: {'friend'},
        ensureFriendshipGrant: (planner, target) async {
          actions.add('grant:$planner:$target');
        },
        revokeGroupGrant: (group, planner, target) async {
          actions.add('revoke:$group:$planner:$target');
        },
      );

      expect(actions, ['grant:friend:me', 'revoke:group-a:friend:me']);
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
