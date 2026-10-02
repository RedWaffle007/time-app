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

/// R4 (2026-10-02): the Plan screen's "Several friends" row — the way into
/// one plan for several friends. It needs two friends to mean anything.
void main() {
  List<PlannerGrant> grants(int n) => [
    for (var i = 0; i < n; i++)
      PlannerGrant(
        plannerUid: 'me',
        targetUid: 'friend-$i',
        groupId: '',
        granted: true,
      ),
  ];

  Widget host(int friends) => ProviderScope(
    overrides: [
      authRepositoryProvider.overrideWithValue(_FakeAuthRepository()),
      effectivePlanningTargetsProvider.overrideWithValue(
        AsyncData(grants(friends)),
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
      home: const ScheduleBuilderScreen(),
    ),
  );

  final row = find.byKey(const ValueKey('plan-several-friends'));

  testWidgets('shown with two or more friends, right under you', (
    tester,
  ) async {
    await tester.pumpWidget(host(2));
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);
    expect(find.text('Several friends'), findsOneWidget);
    expect(
      tester.getTopLeft(row).dy,
      greaterThan(tester.getTopLeft(find.text('Me (myself)')).dy),
    );
    expect(
      tester.getTopLeft(row).dy,
      lessThan(tester.getTopLeft(find.text('Name friend-0')).dy),
    );
  });

  testWidgets('hidden with one friend or none', (tester) async {
    for (final n in [0, 1]) {
      await tester.pumpWidget(host(n));
      await tester.pumpAndSettle();
      expect(row, findsNothing, reason: '$n friends');
    }
  });

  testWidgets('opens the friend checklist and leaves the screen\'s own pick '
      'untouched', (tester) async {
    await tester.pumpWidget(host(3));
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('Choose friends'), findsOneWidget);
    expect(find.text('Name friend-2'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Choose friends'), findsNothing);
    // Nothing was picked: the list is still open, no form.
    expect(find.byKey(const ValueKey('plan-target-chosen')), findsNothing);
    expect(find.byKey(const ValueKey('task-name')), findsNothing);
  });
}

class _FakeAuthRepository implements AuthRepository {
  @override
  User? get currentUser => _FakeUser();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUser implements User {
  @override
  String get uid => 'me';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
