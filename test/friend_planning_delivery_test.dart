import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/notifications/data/http_event_notifier.dart';
import 'package:time_app/features/scheduling/application/planning_target_picker.dart';

void main() {
  group('planning target picker', () {
    test('every friend is a target, with no grant at all', () {
      final targets = effectivePlanningTargets(
        friendUids: {'friend-a', 'friend-b'},
        plannerUid: 'me',
      );

      expect(
        {for (final t in targets) t.targetUid: t.groupId},
        {'friend-a': '', 'friend-b': ''},
      );
      expect(targets.every((t) => t.granted && t.plannerUid == 'me'), isTrue);
    });

    test('never lists yourself, and lists no one without friends', () {
      expect(
        effectivePlanningTargets(
          friendUids: {'me', 'friend'},
          plannerUid: 'me',
        ).map((g) => g.targetUid),
        ['friend'],
      );
      expect(
        effectivePlanningTargets(friendUids: const {}, plannerUid: 'me'),
        isEmpty,
      );
    });

    test('group members are never individual targets (item 3)', () {
      final source = File(
        'lib/features/scheduling/application/planning_target_picker.dart',
      ).readAsStringSync();
      expect(source, isNot(contains('grants')));
      expect(source, isNot(contains('groupPlanningPermissionApplies')));
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
