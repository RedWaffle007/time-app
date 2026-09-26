import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Batch G item 2 (2026-09-27): friendship IS the planning permission. The
/// switch, the "Ask to plan" flow, the grants and their pushes are gone; these
/// pin that they stay gone. The target list itself is covered in
/// `friend_planning_delivery_test.dart`, the rules in
/// `firestore-tests/friendship_permission.test.mjs`.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('the retired permission code is deleted', () {
    for (final path in [
      'lib/features/social/data/planning_permission_repository.dart',
      'lib/features/social/application/planning_permission_migrator.dart',
      'lib/features/social/domain/planning_request.dart',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
  });

  test('a friend\'s profile explains the rule instead of offering a switch or '
      'an ask', () {
    final profile = read(
      'lib/features/social/presentation/user_profile_screen.dart',
    );
    expect(profile, contains('can set alarms for each other.'));
    expect(
      profile,
      contains(
        'To stop one, mark it Done or Skip before it rings, or unfriend.',
      ),
    );
    expect(profile, isNot(contains('SwitchListTile')));
    expect(profile, isNot(contains('Ask to set alarms')));
    expect(profile, isNot(contains('setGrant(')));
  });

  test('the Requests inbox has no planning-permission section', () {
    final inbox = read(
      'lib/features/social/presentation/friend_requests_screen.dart',
    );
    expect(inbox, isNot(contains('Permission to plan')));
    expect(inbox, isNot(contains('_PlanningRow')));
    final providers = read(
      'lib/features/social/application/social_providers.dart',
    );
    expect(providers, isNot(contains('incomingPlanningRequestsProvider')));
    expect(providers, isNot(contains('myEmergencyTargetsProvider')));
  });

  test('the planning-permission push events are gone from the app', () {
    final notifier = read(
      'lib/features/notifications/application/friend_notifier.dart',
    );
    final events = notifier.substring(
      notifier.indexOf('enum FriendNotifyEvent {'),
      notifier.indexOf('}', notifier.indexOf('enum FriendNotifyEvent {')),
    );
    expect(events, isNot(contains('planningRequest')));
    expect(events, isNot(contains('planningApprove')));
  });

  test('Request Plan lists friends, not grants', () {
    final screen = read(
      'lib/features/plan_requests/presentation/plan_request_screens.dart',
    );
    expect(screen, contains('myFriendUidsProvider'));
    expect(screen, isNot(contains('grantsOverMeProvider')));
    final repo = read(
      'lib/features/plan_requests/data/plan_request_repository.dart',
    );
    expect(repo, isNot(contains("collection('plannerGrants')")));
  });

  test('blocking never tries to write a retired friendship grant', () {
    final block = read('lib/features/social/data/block_repository.dart');
    expect(
      block,
      contains("if ((doc.data()['groupId'] ?? '') == '') continue;"),
    );
  });

  test('"How this app works" states the new rule', () {
    final guide = read(
      'lib/features/walkthrough/presentation/how_it_works_screen.dart',
    );
    expect(guide, contains('Friends plan for each other'));
    expect(guide, isNot(contains('A friendship alone grants nothing')));
  });
}
