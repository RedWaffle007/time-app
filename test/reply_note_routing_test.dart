import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/plan/application/plan_intent.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';

/// R6 (2026-10-02): a "Note from {name}" push names the Worker's `replied`
/// event, and a tap opens the plan the note is about.
void main() {
  test('the wire name matches the Worker event', () {
    expect(NotifyEvent.replied.name, 'replied');
  });

  testWidgets('tapping a note push opens that plan, outlined', (tester) async {
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    container.read(notificationRouterProvider).openForPushEvent({
      'event': 'replied',
      'itemId': 'item-1',
    });
    await tester.pumpAndSettle();

    expect(find.text('Plan'), findsOneWidget);
    expect(container.read(planIntentProvider)?.itemId, 'item-1');
  });
}
