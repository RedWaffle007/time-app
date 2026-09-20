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
    test('shows a friend only once across friendship and group grants', () {
      final targets = uniquePlanningTargets([
        grant('friend', 'group-a'),
        grant('friend', ''),
        grant('friend', 'group-b'),
      ]);

      expect(targets, hasLength(1));
      expect(targets.single.targetUid, 'friend');
      expect(targets.single.groupId, isEmpty);
    });

    test('keeps distinct people and ignores revoked grants', () {
      final targets = uniquePlanningTargets([
        grant('friend-a', 'group-a'),
        grant('friend-b', 'group-a'),
        const PlannerGrant(
          plannerUid: 'me',
          targetUid: 'revoked',
          groupId: '',
          granted: false,
        ),
      ]);

      expect(targets.map((g) => g.targetUid), ['friend-a', 'friend-b']);
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
