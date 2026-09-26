import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/features/notifications/data/foreground_push_presenter.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';

/// Item 20 (2026-09-26): a Worker-settled item notifies both people; each tap
/// lands where that person reviews it.
void main() {
  Future<void> open(WidgetTester tester, Map<String, dynamic> data) async {
    final router = GoRouter(
      initialLocation: Routes.you,
      routes: [
        GoRoute(
          path: Routes.plan,
          builder: (_, _) => const Text('Plan'),
          routes: [
            GoRoute(path: 'history', builder: (_, _) => const Text('History')),
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

  Map<String, dynamic> lapsed(String audience) => {
    'type': 'lapsed',
    'event': 'lapsed',
    'audience': audience,
    'targetUid': 'TARGET',
    'itemId': 'item-1',
  };

  testWidgets('the person lands in History, where settled plans live', (
    tester,
  ) async {
    await open(tester, lapsed('target'));
    expect(find.text('History'), findsOneWidget);
  });

  testWidgets('the planner lands on the Plan activity surface', (tester) async {
    await open(tester, lapsed('planner'));
    expect(find.text('Plan'), findsOneWidget);
  });

  test('a lapse is a real notification in the app, not the outcome pop-up', () {
    // The pop-up (item 18) announces a person's own Done/Skip; an automatic
    // lapse has no pop-up record, so its push must still be posted.
    expect(isAnnouncedInApp(lapsed('target')), isFalse);
    expect(isAnnouncedInApp(lapsed('planner')), isFalse);
    expect(channelIdForPush(lapsed('planner')), kPlannerActivityChannelId);
  });
}
