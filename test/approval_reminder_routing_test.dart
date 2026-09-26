import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/features/notifications/data/foreground_push_presenter.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';

/// An approval reminder (Worker cron, 2026-09-26) must land on the queue where
/// the plan can be approved or rejected — from the tray and from a
/// foreground-shown notification alike.
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
              path: 'approvals',
              builder: (_, _) => const Text('Approvals'),
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

  const reminder = {
    'type': 'approvalReminder',
    'event': 'approvalReminder',
    'targetUid': 'TARGET',
    'itemId': 'item-1',
  };

  // F2: there is no approvals queue; a legacy approval reminder (an older
  // Worker may still send one) lands on My Schedule.
  testWidgets('a legacy approval reminder opens My Schedule', (tester) async {
    await open(tester, reminder);
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Approvals'), findsNothing);
  });

  testWidgets('a foreground-notification tap routes the same way', (
    tester,
  ) async {
    final decoded = decodePushTapPayload(encodePushTapPayload(reminder))!;
    await open(tester, decoded);
    expect(find.text('Plan'), findsOneWidget);
  });

  test('a Done-style fallback never swallows a reminder', () {
    expect(fallbackPresentation(reminder), ForegroundPushPresentation.snackbar);
  });

  testWidgets('the planner heads-up opens Plan activity, not the queue', (
    tester,
  ) async {
    // The queue belongs to the target; the planner reviews their own plan.
    await open(tester, {
      'type': 'approvalPending',
      'event': 'approvalPending',
      'targetUid': 'TARGET',
      'itemId': 'item-1',
    });
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Approvals'), findsNothing);
  });

  test('the heads-up is a real notification in the app, on activity', () {
    const data = {'event': 'approvalPending', 'itemId': 'item-1'};
    expect(isAnnouncedInApp(data), isFalse);
    expect(channelIdForPush(data), kPlannerActivityChannelId);
  });
}
