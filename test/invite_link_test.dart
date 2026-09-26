import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/core/config/notify_config.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/invites/application/pending_invite.dart';
import 'package:time_app/features/invites/domain/invite_link.dart';
import 'package:time_app/features/invites/presentation/pending_invite_listener.dart';
import 'package:time_app/features/social/application/social_providers.dart';
import 'package:time_app/features/social/data/username_repository.dart';
import 'package:time_app/routing/app_router.dart';

/// Item 17 (2026-09-26): tap-to-open invite links.

class _Usernames implements UsernameRepository {
  _Usernames(this.map);
  final Map<String, String> map;
  final looked = <String>[];

  @override
  Future<String?> lookup(String rawHandle) async {
    looked.add(rawHandle);
    return map[rawHandle];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('InviteLink.parsePath', () {
    test('parity: the app agrees with every shared Worker fixture', () {
      final fixture =
          jsonDecode(File('test/fixtures/invite_paths.json').readAsStringSync())
              as Map<String, dynamic>;
      for (final raw in fixture['cases'] as List) {
        final c = raw as Map<String, dynamic>;
        final parsed = InviteLink.parsePath(c['path'] as String);
        if (c['kind'] == null) {
          expect(parsed, isNull, reason: c['path'] as String);
        } else {
          expect(
            parsed,
            InviteLink(
              c['kind'] == 'user' ? InviteKind.user : InviteKind.group,
              c['value'] as String,
            ),
            reason: c['path'] as String,
          );
        }
      }
    });

    test('links round-trip through the Worker host', () {
      for (final invite in const [
        InviteLink(InviteKind.user, 'ana_b'),
        InviteLink(InviteKind.group, 'HJK234'),
      ]) {
        final uri = invite.toUri();
        expect(uri.scheme, 'https');
        expect(uri.host, Uri.parse(kNotifyEndpoint).host);
        expect(InviteLink.parsePath(uri.path), invite);
      }
    });
  });

  group('share text', () {
    test('friend invite carries the tap-to-open link', () {
      expect(
        friendInviteShareText('Ana_B'),
        'Add me on Checkmate: $kNotifyEndpoint/i/u/ana_b',
      );
    });

    test('group invite carries the link AND the typeable code', () {
      final text = groupInviteShareText('Family', 'HJK234');
      expect(text, contains('$kNotifyEndpoint/i/g/HJK234'));
      expect(text, contains('HJK234 in the app'));
      expect(text, startsWith('Join my group "Family" on Checkmate: '));
    });

    test('the group screen and friends screen use them', () {
      expect(
        File(
          'lib/features/groups/presentation/group_detail_screen.dart',
        ).readAsStringSync(),
        contains('groupInviteShareText('),
      );
      expect(
        File(
          'lib/features/social/presentation/friends_screen.dart',
        ).readAsStringSync(),
        contains('friendInviteShareText('),
      );
    });
  });

  group('Android App Links', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    test('a verified https filter for the Worker host and /i/ only', () {
      expect(manifest, contains('android:autoVerify="true"'));
      expect(
        manifest,
        contains('android:host="${Uri.parse(kNotifyEndpoint).host}"'),
      );
      expect(manifest, contains('android:pathPrefix="/i/"'));
      expect(manifest, contains('android.intent.category.BROWSABLE'));
    });

    test('Flutter deep linking is on, so go_router receives the path', () {
      expect(
        RegExp(
          r'flutter_deeplinking_enabled"\s*android:value="true"',
        ).hasMatch(manifest),
        isTrue,
      );
    });

    test('the router parks /i/ links instead of routing to a screen', () {
      final router = File('lib/routing/app_router.dart').readAsStringSync();
      final redirect = router.indexOf('redirect: (context, state) {');
      final park = router.indexOf("startsWith('/i/')", redirect);
      final authGate = router.indexOf('if (!loggedIn && !atAuth)', redirect);
      expect(park, greaterThan(redirect));
      expect(park, lessThan(authGate), reason: 'parked before the auth gate');
      expect(router, contains('pendingInviteProvider.notifier).set(invite)'));
    });
  });

  group('PendingInviteListener', () {
    Future<(ProviderContainer, _Usernames)> pump(
      WidgetTester tester, {
      InviteLink? pending,
      Map<String, String> usernames = const {'ana_b': 'FRIEND'},
    }) async {
      final repo = _Usernames(usernames);
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(
              body: PendingInviteListener(child: Text('HOME')),
            ),
          ),
          GoRoute(
            path: '${Routes.userProfile}/:uid',
            builder: (_, state) =>
                Text('PROFILE ${state.pathParameters['uid']}'),
          ),
        ],
      );
      addTearDown(router.dispose);
      final container = ProviderContainer(
        overrides: [
          currentUidProvider.overrideWithValue('ME'),
          usernameRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      if (pending != null) {
        container.read(pendingInviteProvider.notifier).set(pending);
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: AppTheme.light,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (container, repo);
    }

    testWidgets('an invite parked during sign-in opens the friend profile', (
      tester,
    ) async {
      final (container, repo) = await pump(
        tester,
        pending: const InviteLink(InviteKind.user, 'ana_b'),
      );
      expect(repo.looked, ['ana_b']);
      expect(find.text('PROFILE FRIEND'), findsOneWidget);
      expect(container.read(pendingInviteProvider), isNull, reason: 'once');
    });

    testWidgets('an invite arriving while the app is open is handled too', (
      tester,
    ) async {
      final (container, _) = await pump(tester);
      expect(find.text('HOME'), findsOneWidget);
      container
          .read(pendingInviteProvider.notifier)
          .set(const InviteLink(InviteKind.user, 'ana_b'));
      await tester.pumpAndSettle();
      expect(find.text('PROFILE FRIEND'), findsOneWidget);
    });

    testWidgets('a group invite opens the join dialog, code prefilled', (
      tester,
    ) async {
      await pump(tester, pending: const InviteLink(InviteKind.group, 'HJK234'));
      expect(find.text('Join a group'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'HJK234'), findsOneWidget);
      // Nothing is sent until the person taps Join.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Join a group'), findsNothing);
    });

    testWidgets('an unknown username says so and stays put', (tester) async {
      await pump(tester, pending: const InviteLink(InviteKind.user, 'ghost'));
      expect(find.text('No one is using the username ghost.'), findsOneWidget);
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('your own link does not open your own profile', (tester) async {
      await pump(
        tester,
        pending: const InviteLink(InviteKind.user, 'me_myself'),
        usernames: const {'me_myself': 'ME'},
      );
      expect(find.text('That is your own invite link.'), findsOneWidget);
      expect(find.textContaining('PROFILE'), findsNothing);
    });
  });
}
