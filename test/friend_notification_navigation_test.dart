import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';

void main() {
  testWidgets('an inactivity push opens the landing Plan surface', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: Routes.you,
      routes: [
        GoRoute(path: Routes.plan, builder: (_, _) => const Text('Plan')),
        GoRoute(path: Routes.you, builder: (_, _) => const Text('You')),
      ],
    );
    final container = ProviderContainer(
      overrides: [routerProvider.overrideWithValue(router)],
    );
    addTearDown(container.dispose);
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('You'), findsOneWidget);

    container.read(notificationRouterProvider).openForPushEvent({
      'event': 'inactivity',
    });
    await tester.pumpAndSettle();

    expect(find.text('Plan'), findsOneWidget);
  });

  testWidgets(
    'friend acceptance opens Friends above You and Back returns to main tabs',
    (tester) async {
      final router = GoRouter(
        initialLocation: Routes.plan,
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) => Scaffold(
              body: shell,
              bottomNavigationBar: const Text('Main tabs'),
            ),
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: Routes.plan,
                    builder: (_, _) => const Text('Plan'),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: Routes.you,
                    builder: (_, _) => const Text('You'),
                    routes: [
                      GoRoute(
                        path: 'friends',
                        builder: (_, _) => const Text('Friends'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [routerProvider.overrideWithValue(router)],
      );
      addTearDown(container.dispose);
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      container.read(notificationRouterProvider).openForPushEvent({
        'event': 'friendAccept',
      });
      await tester.pumpAndSettle();

      expect(Routes.friends, '${Routes.you}/friends');
      expect(find.text('Friends'), findsOneWidget);
      expect(find.text('Main tabs'), findsOneWidget);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();

      expect(find.text('You'), findsOneWidget);
      expect(find.text('Friends'), findsNothing);
      expect(find.text('Main tabs'), findsOneWidget);
    },
  );
}
