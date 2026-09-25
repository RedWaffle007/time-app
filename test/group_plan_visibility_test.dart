import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/groups/application/group_providers.dart';
import 'package:time_app/features/groups/domain/group.dart';
import 'package:time_app/features/groups/domain/membership.dart';
import 'package:time_app/features/groups/domain/planner_grant.dart';
import 'package:time_app/features/groups/presentation/group_detail_screen.dart';
import 'package:time_app/features/social/application/social_providers.dart';
import 'package:time_app/features/social/domain/friendship.dart';

void main() {
  testWidgets('Testmates group planning uses a friendship-scoped permission', (
    tester,
  ) async {
    const groupId = 'testmates';
    const group = Group(
      id: groupId,
      name: 'Testmates',
      ownerUid: 'me',
      joinCode: 'TEST42',
      memberUids: ['me', 'friend'],
    );
    const members = [
      Membership(uid: 'me', name: 'Me'),
      Membership(uid: 'friend', name: '{planner}'),
    ];
    const friendship = Friendship(id: 'friend_me', uidA: 'friend', uidB: 'me');
    const friendshipGrant = PlannerGrant(
      plannerUid: 'me',
      targetUid: 'friend',
      groupId: '',
      granted: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          myGroupsProvider.overrideWithValue(const AsyncData([group])),
          membersProvider(groupId).overrideWithValue(const AsyncData(members)),
          // This is the historical failure shape: after friend permissions
          // moved to profiles, the group itself has no planner-grant row.
          grantsProvider(
            groupId,
          ).overrideWithValue(const AsyncData(<PlannerGrant>[])),
          groupJoinRequestsProvider(
            groupId,
          ).overrideWithValue(const AsyncData([])),
          myFriendshipsProvider.overrideWithValue(
            const AsyncData([friendship]),
          ),
          effectivePlanningTargetsProvider.overrideWithValue(
            const AsyncData([friendshipGrant]),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const GroupDetailScreen(groupId: groupId),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Add photo'), findsOneWidget);
    expect(find.text('Plan for the group'), findsOneWidget);
    expect(
      find.text('One item for 1 member you can plan for, plus you'),
      findsOneWidget,
    );

    await tester.tap(find.text('Plan for the group'));
    await tester.pumpAndSettle();

    expect(find.text('Plan for Testmates'), findsOneWidget);
    expect(find.textContaining('Goes to 2 members'), findsOneWidget);
  });
}
