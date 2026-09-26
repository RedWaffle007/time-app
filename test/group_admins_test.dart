import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/groups/application/group_providers.dart';
import 'package:time_app/features/groups/domain/group.dart';
import 'package:time_app/features/groups/domain/group_join_request.dart';
import 'package:time_app/features/groups/domain/membership.dart';
import 'package:time_app/features/groups/presentation/group_detail_screen.dart';
import 'package:time_app/features/social/application/social_providers.dart';

/// Batch G item 3 (2026-09-27): WhatsApp-style groups. The creator is always
/// an admin; only the creator makes admins; admins add, approve and remove;
/// any member plans for the whole group with no permission step.
void main() {
  const groupId = 'team';
  const members = [
    Membership(uid: 'owner', name: 'Test Owner'),
    Membership(uid: 'admin', name: 'Test Admin'),
    Membership(uid: 'member', name: 'Test Member'),
  ];
  const team = Group(
    id: groupId,
    name: 'Team',
    ownerUid: 'owner',
    joinCode: 'TEAM42',
    memberUids: ['owner', 'admin', 'member'],
    adminUids: ['owner', 'admin'],
  );
  const request = GroupJoinRequest(
    candidateUid: 'candidate',
    candidateName: 'Test Candidate',
    requestedByUid: 'candidate',
    source: 'code',
    status: 'pending',
    requiredApproverUids: [],
    approvalUids: [],
  );

  Future<void> open(WidgetTester tester, String me) async {
    // Tall enough that the whole member list is built (ListView is lazy).
    tester.view.physicalSize = const Size(1080, 7200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue(me),
          myGroupsProvider.overrideWithValue(const AsyncData([team])),
          membersProvider(groupId).overrideWithValue(const AsyncData(members)),
          groupJoinRequestsProvider(
            groupId,
          ).overrideWithValue(const AsyncData([request])),
          myFriendshipsProvider.overrideWithValue(const AsyncData([])),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const GroupDetailScreen(groupId: groupId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the overflow menu on [name]'s member row, scrolling it into view.
  Future<void> openRowMenu(WidgetTester tester, String name) async {
    await tester.ensureVisible(find.text(name));
    await tester.pumpAndSettle();
    final row = find.ancestor(
      of: find.text(name),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byTooltip('More')),
    );
    await tester.pumpAndSettle();
  }

  group('Group.isAdmin', () {
    test('the creator always; listed admins only while members', () {
      expect(team.isAdmin('owner'), isTrue);
      expect(team.isAdmin('admin'), isTrue);
      expect(team.isAdmin('member'), isFalse);
      const left = Group(
        id: 'g',
        name: 'G',
        ownerUid: 'owner',
        joinCode: 'X',
        memberUids: ['owner'],
        adminUids: ['gone'],
      );
      expect(left.isAdmin('gone'), isFalse);
      const legacy = Group(
        id: 'g',
        name: 'G',
        ownerUid: 'owner',
        joinCode: 'X',
        memberUids: ['owner', 'member'],
      );
      expect(legacy.isAdmin('owner'), isTrue);
      expect(legacy.isAdmin('member'), isFalse);
    });
  });

  testWidgets('any member plans for the WHOLE group, no permission step', (
    tester,
  ) async {
    await open(tester, 'member');
    expect(find.text('One alarm for all 2 members, plus you'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.textContaining('can plan for me'), findsNothing);

    await tester.tap(find.text('Plan for the group'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Rings for 3 members'), findsOneWidget);
  });

  testWidgets('admins are labelled; the creator is marked', (tester) async {
    await open(tester, 'member');
    expect(find.text('Creator · admin'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
  });

  testWidgets('a plain member sees no join queue and cannot remove anyone', (
    tester,
  ) async {
    await open(tester, 'member');
    expect(find.text('Join requests'), findsNothing);
    expect(find.text('Test Candidate'), findsNothing);
    expect(
      find.byTooltip('More'),
      findsOneWidget,
    ); // only Leave, in the app bar
    expect(
      find.text('A group admin approves before they join'),
      findsOneWidget,
    );
  });

  testWidgets('an admin sees the queue with approve/reject and adds directly', (
    tester,
  ) async {
    await open(tester, 'admin');
    expect(find.text('Join requests'), findsOneWidget);
    expect(find.text('Asked with the invite code'), findsOneWidget);
    expect(find.byTooltip('Approve Test Candidate'), findsOneWidget);
    expect(find.byTooltip('Reject Test Candidate'), findsOneWidget);
    expect(find.text('They join right away'), findsOneWidget);
  });

  testWidgets('an admin may remove members but not make admins', (
    tester,
  ) async {
    await open(tester, 'admin');
    await openRowMenu(tester, 'Test Member');
    expect(find.text('Remove from group'), findsOneWidget);
    expect(find.text('Make admin'), findsNothing);
  });

  testWidgets('nobody gets a menu on the creator\'s row', (tester) async {
    await open(tester, 'admin');
    await tester.ensureVisible(find.text('Test Owner'));
    await tester.pumpAndSettle();
    // The row must really be built, or "no menu" would pass vacuously.
    expect(find.text('Test Owner'), findsOneWidget);
    final creatorRow = find.ancestor(
      of: find.text('Test Owner'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: creatorRow, matching: find.byTooltip('More')),
      findsNothing,
    );
  });

  testWidgets('the creator makes admins and removes admin rights', (
    tester,
  ) async {
    await open(tester, 'owner');
    await openRowMenu(tester, 'Test Member');
    expect(find.text('Make admin'), findsOneWidget);
    expect(find.text('Remove from group'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await openRowMenu(tester, 'Test Admin');
    expect(find.text('Remove as admin'), findsOneWidget);
  });

  // The test font's glyphs are wide, so this is the long-label case: before the
  // fix "Remove from group" overflowed the popup's width cap.
  testWidgets('menu labels never overflow the popup', (tester) async {
    await open(tester, 'owner');
    await openRowMenu(tester, 'Test Member');
    expect(find.text('Remove from group'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
