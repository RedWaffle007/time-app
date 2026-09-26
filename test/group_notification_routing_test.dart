import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';

/// Batch G items 3 + 4: every group push opens that group.
void main() {
  Future<void> open(WidgetTester tester, Map<String, dynamic> data) async {
    final router = GoRouter(
      initialLocation: Routes.you,
      routes: [
        GoRoute(
          path: Routes.plan,
          builder: (_, _) => const Text('Plan'),
          routes: [
            GoRoute(
              path: 'groups/:id',
              builder: (_, state) =>
                  Text('Group ${state.pathParameters['id']}'),
            ),
          ],
        ),
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
    container.read(notificationRouterProvider).openForPushEvent(data);
    await tester.pumpAndSettle();
  }

  for (final type in [
    'groupJoinApproved',
    'groupJoinRequested',
    'groupBusy',
    'groupPlanSummary',
  ]) {
    testWidgets('$type opens the group', (tester) async {
      await open(tester, {'type': type, 'event': type, 'groupId': 'g1'});
      expect(find.text('Group g1'), findsOneWidget);
    });
  }

  testWidgets('a missing or unsafe group id falls back to Plan', (
    tester,
  ) async {
    await open(tester, {
      'type': 'groupBusy',
      'event': 'groupBusy',
      'groupId': 'a/b',
    });
    expect(find.text('Plan'), findsOneWidget);
  });
}
