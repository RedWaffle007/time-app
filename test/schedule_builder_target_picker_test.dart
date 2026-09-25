import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/data/auth_repository.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/groups/domain/planner_grant.dart';
import 'package:time_app/features/scheduling/presentation/schedule_builder_screen.dart';
import 'package:time_app/features/social/application/social_providers.dart';

/// Regression (2026-09-25): after picking a person the list stayed on screen
/// and the planner had to scroll past it to reach the planning fields.
void main() {
  const friendCount = 12;
  final grants = [
    for (var i = 0; i < friendCount; i++)
      PlannerGrant(
        plannerUid: 'me',
        targetUid: 'friend-$i',
        groupId: '',
        granted: true,
      ),
  ];

  Widget host({String? initialTargetUid}) => ProviderScope(
    overrides: [
      authRepositoryProvider.overrideWithValue(_FakeAuthRepository()),
      effectivePlanningTargetsProvider.overrideWithValue(AsyncData(grants)),
      iCanEmergencyPlanForProvider.overrideWith(
        (ref, uid) => const AsyncData(false),
      ),
      profileByUidProvider.overrideWith(
        (ref, uid) => Stream.value(
          UserProfile(
            uid: uid,
            name: uid == 'me' ? 'Me' : 'Name $uid',
            homeTimezone: 'Etc/UTC',
          ),
        ),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: ScheduleBuilderScreen(initialTargetUid: initialTargetUid),
    ),
  );

  final titleField = find.widgetWithText(TextField, 'Title (what to do)');
  final change = find.byKey(const ValueKey('plan-target-change'));

  testWidgets('before a pick, everyone is listed and no form is shown', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('Me (myself)'), findsOneWidget);
    expect(find.text('Name friend-0'), findsOneWidget);
    expect(titleField, findsNothing);
    expect(change, findsNothing);
  });

  testWidgets(
    'picking a far-down friend collapses the list and lands on the fields',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      final last = find.text('Name friend-${friendCount - 1}');
      await tester.scrollUntilVisible(last, 200);
      await tester.tap(last);
      await tester.pumpAndSettle();

      // Only the chosen person remains, as one row with a way back.
      expect(find.text('Name friend-0'), findsNothing);
      expect(find.text('Me (myself)'), findsNothing);
      expect(find.byKey(const ValueKey('plan-target-chosen')), findsOneWidget);
      expect(find.text('Name friend-${friendCount - 1}'), findsOneWidget);
      expect(change, findsOneWidget);

      // The planning fields are on screen with no scrolling: back at the top.
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.pixels, 0);
      final screen = tester.getRect(find.byType(Scaffold));
      final title = tester.getRect(titleField);
      expect(title.bottom, lessThanOrEqualTo(screen.bottom));
      expect(
        tester.getRect(find.text('Pick date')).bottom,
        lessThanOrEqualTo(screen.bottom),
      );
    },
  );

  testWidgets('Change reopens the list, and a new pick collapses it again', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name friend-0'));
    await tester.pumpAndSettle();

    await tester.tap(change);
    await tester.pumpAndSettle();
    expect(find.text('Me (myself)'), findsOneWidget);
    expect(find.text('Name friend-1'), findsOneWidget);

    await tester.tap(find.text('Me (myself)'));
    await tester.pumpAndSettle();
    expect(find.text('Name friend-0'), findsNothing);
    expect(find.text('Me (myself)'), findsOneWidget);
    expect(change, findsOneWidget);
    expect(titleField, findsOneWidget);
  });

  testWidgets('a pre-selected target (voice flow) opens already collapsed', (
    tester,
  ) async {
    await tester.pumpWidget(host(initialTargetUid: 'friend-3'));
    await tester.pumpAndSettle();

    expect(find.text('Name friend-3'), findsOneWidget);
    expect(find.text('Name friend-0'), findsNothing);
    expect(change, findsOneWidget);
    expect(titleField, findsOneWidget);
  });

  testWidgets('a name still loading never shows the raw uid', (tester) async {
    // Regression (2026-09-25): first Plan tap flashed uids for ~0.2s.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(_FakeAuthRepository()),
          effectivePlanningTargetsProvider.overrideWithValue(AsyncData(grants)),
          iCanEmergencyPlanForProvider.overrideWith(
            (ref, uid) => const AsyncData(false),
          ),
          profileByUidProvider.overrideWith(
            (ref, uid) => const Stream<UserProfile?>.empty(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const ScheduleBuilderScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('friend-0'), findsNothing);
    expect(find.textContaining('friend-'), findsNothing);
    expect(find.text(kProfileNameLoading), findsWidgets);

    await tester.tap(find.text(kProfileNameLoading).first);
    await tester.pump();
    expect(find.textContaining('friend-'), findsNothing);
  });

  testWidgets('entered fields survive changing the person', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name friend-0'));
    await tester.pumpAndSettle();
    await tester.enterText(titleField, 'Stretch');

    await tester.tap(change);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name friend-1'));
    await tester.pumpAndSettle();

    expect(find.text('Stretch'), findsOneWidget);
  });
}

class _FakeUser implements User {
  @override
  String get uid => 'me';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthRepository implements AuthRepository {
  @override
  User? get currentUser => _FakeUser();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
