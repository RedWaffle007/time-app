import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/features/notifications/application/friend_notifier.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/reminders/application/dismiss_notifying_timeline.dart';
import 'package:time_app/features/reminders/data/alarm_timeline_repository.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';

class _Timeline implements AlarmTimelineRepository {
  final calls = <String>[];
  bool failDismiss = false;

  @override
  Future<void> recordDismissed(String targetUid, String itemId, DateTime at) {
    calls.add('dismissed:$itemId');
    if (failDismiss) return Future.error(StateError('offline'));
    return Future.value();
  }

  @override
  Future<void> recordRang(String targetUid, String itemId, DateTime at) async =>
      calls.add('rang:$itemId');

  @override
  Future<void> recordUnavailable(
    String targetUid,
    String itemId,
    DateTime at,
  ) async => calls.add('unavailable:$itemId');
}

class _Notifier implements NotificationEventNotifier {
  final events = <(NotifyEvent, String, String)>[];

  @override
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async => events.add((event, targetUid, itemId));

  @override
  Future<NotificationDeliveryResult> notifyConfirmed({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async {
    events.add((event, targetUid, itemId));
    return const NotificationDeliveryResult(delivered: true, reason: 'sent');
  }
}

GoRouter _router() => GoRouter(
  initialLocation: Routes.you,
  routes: [
    GoRoute(
      path: Routes.plan,
      builder: (_, _) => const Text('Plan'),
      routes: [
        GoRoute(
          path: 'groups/:groupId',
          builder: (_, state) =>
              Text('Group ${state.pathParameters['groupId']}'),
        ),
      ],
    ),
    GoRoute(path: Routes.you, builder: (_, _) => const Text('You')),
  ],
);

Future<void> _open(WidgetTester tester, Map<String, dynamic> data) async {
  final router = _router();
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
  container.read(notificationRouterProvider).openForPushEvent(data);
  await tester.pumpAndSettle();
}

void main() {
  final at = DateTime.utc(2030, 1, 1, 10);

  group('dismiss → planner push', () {
    test('a recorded dismissal is followed by one dismissed push', () async {
      final timeline = _Timeline();
      final notifier = _Notifier();
      await DismissNotifyingTimelineRepository(
        timeline,
        notifier,
      ).recordDismissed('TARGET', 'item-1', at);
      await Future<void>.delayed(Duration.zero);

      expect(timeline.calls, ['dismissed:item-1']);
      expect(notifier.events, [(NotifyEvent.dismissed, 'TARGET', 'item-1')]);
    });

    test('no push when the dismissal did not persist', () async {
      final timeline = _Timeline()..failDismiss = true;
      final notifier = _Notifier();
      await expectLater(
        DismissNotifyingTimelineRepository(
          timeline,
          notifier,
        ).recordDismissed('TARGET', 'item-1', at),
        throwsStateError,
      );
      expect(notifier.events, isEmpty);
    });

    test('rang and unavailable never push a dismissal', () async {
      final timeline = _Timeline();
      final notifier = _Notifier();
      final repo = DismissNotifyingTimelineRepository(timeline, notifier);
      await repo.recordRang('TARGET', 'item-1', at);
      await repo.recordUnavailable('TARGET', 'item-1', at);

      expect(timeline.calls, ['rang:item-1', 'unavailable:item-1']);
      expect(notifier.events, isEmpty);
    });

    test('the wire names match the Worker events', () {
      expect(NotifyEvent.dismissed.name, 'dismissed');
      expect(FriendNotifyEvent.groupJoinApproved.name, 'groupJoinApproved');
    });
  });

  group('tap routing', () {
    testWidgets('a dismissed push opens the planner Activity surface', (
      tester,
    ) async {
      await _open(tester, {'event': 'dismissed', 'itemId': 'item-1'});
      expect(find.text('Plan'), findsOneWidget);
    });

    testWidgets('a group-join push opens that group', (tester) async {
      await _open(tester, {'event': 'groupJoinApproved', 'groupId': 'g1'});
      expect(find.text('Group g1'), findsOneWidget);
    });

    testWidgets('a group-join push with no usable id falls back to Plan', (
      tester,
    ) async {
      await _open(tester, {'event': 'groupJoinApproved', 'groupId': 'a/b'});
      expect(find.text('Plan'), findsOneWidget);
    });
  });
}
