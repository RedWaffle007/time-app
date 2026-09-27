import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/applock/application/app_lock_providers.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/data/profile_repository.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/auth/presentation/profile_edit_screen.dart';
import 'package:time_app/features/home/presentation/you_screen.dart';
import 'package:time_app/features/settings/presentation/settings_screen.dart';
import 'package:time_app/features/social/application/social_providers.dart';
import 'package:time_app/features/social/application/stats_providers.dart';
import 'package:time_app/features/social/data/friend_repository.dart';
import 'package:time_app/features/social/domain/profile_visibility.dart';
import 'package:time_app/features/social/presentation/user_profile_screen.dart';

/// Batch H1–H3 (DECISIONS.md "You = your profile; Settings holds the rest").
void main() {
  const me = UserProfile(
    uid: 'me',
    name: 'Test Planner',
    homeTimezone: 'UTC',
    username: 'test_planner',
    bio: 'Short bio',
  );
  const other = UserProfile(
    uid: 'other',
    name: 'Other Person',
    homeTimezone: 'UTC',
    username: 'other_person',
  );

  List<dynamic> profileOverrides(
    UserProfile profile,
    ProfileRelation relation,
  ) => [
    profileByUidProvider(
      profile.uid,
    ).overrideWith((ref) => Stream.value(profile)),
    profileVisibilityProvider(profile.uid).overrideWithValue(
      AsyncData(visibilityFor(relation: relation, isPublic: true)),
    ),
    friendCountForProvider(
      profile.uid,
    ).overrideWithValue(relation == ProfileRelation.self ? 3 : null),
    profileStatsProvider(profile.uid).overrideWithValue(const AsyncData([])),
    friendRepositoryProvider.overrideWithValue(_NoFriendRepository()),
    outgoingRequestToProvider(
      profile.uid,
    ).overrideWithValue(const AsyncData(null)),
  ];

  Widget app(Widget home, List<dynamic> overrides, {ThemeData? theme}) =>
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          profileProvider.overrideWith((ref) => Stream.value(me)),
          incomingRequestCountProvider.overrideWithValue(2),
          appLockInitiallyEnabledProvider.overrideWithValue(false),
          ...overrides,
        ].cast(),
        child: MaterialApp(theme: theme ?? AppTheme.light, home: home),
      );

  group('H1 — You is your own profile', () {
    testWidgets('renders your profile with Edit profile and Settings', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(const YouScreen(), profileOverrides(me, ProfileRelation.self)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ProfileBody), findsOneWidget);
      expect(find.text('@test_planner'), findsWidgets); // app bar + header
      expect(find.text('Test Planner'), findsOneWidget);
      expect(find.text('Short bio'), findsOneWidget);
      expect(find.byKey(const ValueKey('edit-profile')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
      expect(find.text('Friends'), findsOneWidget);
      expect(find.text('Voice notes'), findsOneWidget);
      expect(find.text('3 friends'), findsOneWidget);
      // Settings items no longer live on You.
      expect(find.text('Sign out'), findsNothing);
      expect(find.text('Theme'), findsNothing);
      expect(find.text('Reminders & permissions'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dark theme renders without exceptions', (tester) async {
      await tester.pumpWidget(
        app(
          const YouScreen(),
          profileOverrides(me, ProfileRelation.self),
          theme: AppTheme.dark,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    for (final relation in [
      ProfileRelation.none,
      ProfileRelation.friend,
      ProfileRelation.requestSent,
    ]) {
      testWidgets('someone else\'s profile never shows Edit profile '
          '(${relation.name})', (tester) async {
        await tester.pumpWidget(
          app(
            const UserProfileScreen(uid: 'other'),
            profileOverrides(other, relation),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Other Person'), findsOneWidget);
        expect(find.byKey(const ValueKey('edit-profile')), findsNothing);
        expect(find.text('Voice notes'), findsNothing);
      });
    }

    testWidgets('your own /u/ profile shows Edit profile too', (tester) async {
      await tester.pumpWidget(
        app(
          const UserProfileScreen(uid: 'me'),
          profileOverrides(me, ProfileRelation.self),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit-profile')), findsOneWidget);
    });
  });

  group('H2 — Settings holds the rest', () {
    testWidgets('every moved item is here', (tester) async {
      tester.view.physicalSize = const Size(400 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(const SettingsScreen(), const []));
      await tester.pumpAndSettle();

      for (final label in [
        'Reminders & permissions',
        'Quiet hours',
        'Theme',
        'How this app works',
        'Sign out',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('This device'), findsOneWidget);
      expect(find.byType(QuietHoursTile), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('quiet hours save the moment they are switched on', (
      tester,
    ) async {
      final repo = _RecordingProfileRepository();
      await tester.pumpWidget(
        app(const SettingsScreen(), [
          profileRepositoryProvider.overrideWithValue(repo),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('quiet-hours-switch')));
      await tester.pumpAndSettle();
      expect(repo.quietWrites, [(22 * 60, 7 * 60)]);
    });
  });

  group('H3 — Edit profile is your public identity only', () {
    testWidgets('no quiet hours or device options remain', (tester) async {
      await tester.pumpWidget(app(const ProfileEditScreen(), const []));
      await tester.pumpAndSettle();
      expect(find.text('Quiet hours'), findsNothing);
      expect(find.text('This device'), findsNothing);
      expect(find.text('Identity'), findsOneWidget);
      expect(find.text('Public profile'), findsWidgets);
    });

    testWidgets('About you clears in one tap', (tester) async {
      await tester.pumpWidget(app(const ProfileEditScreen(), const []));
      await tester.pumpAndSettle();
      expect(find.text('Short bio'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('clear-bio')));
      await tester.tap(find.byKey(const ValueKey('clear-bio')));
      await tester.pumpAndSettle();
      expect(find.text('Short bio'), findsNothing);
      expect(find.byKey(const ValueKey('clear-bio')), findsNothing);
    });
  });
}

/// Records quiet-hours writes; any other call is a test failure.
class _RecordingProfileRepository implements ProfileRepository {
  final quietWrites = <(int?, int?)>[];

  @override
  Future<void> updateQuietHours({
    required String uid,
    int? startMinutes,
    int? endMinutes,
  }) async {
    quietWrites.add((startMinutes, endMinutes));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// Rendering a relationship slot reads the repository; no test here writes.
class _NoFriendRepository implements FriendRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
