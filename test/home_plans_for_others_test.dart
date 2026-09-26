import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/groups/application/group_providers.dart';
import 'package:time_app/features/outcomes/application/schedule_partition.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/plan/application/plan_intent.dart';
import 'package:time_app/features/plan/presentation/plan_shell.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/planner_activity_screen.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';
import 'package:timezone/data/latest.dart' as tz_data;

/// Batch G item 7 (2026-09-27): "My Schedule" is Home, and a plan you set for
/// someone else stays on Home until they answer it — then it moves to
/// Activity.
void main() {
  setUpAll(tz_data.initializeTimeZones);
  final soon = DateTime.now().toUtc().add(const Duration(hours: 3));

  ScheduleItem plan(
    String id, {
    String target = 'friend',
    String creator = 'me',
    ScheduleItemStatus status = ScheduleItemStatus.approved,
    ScheduleOutcome? outcome,
  }) => ScheduleItem(
    id: id,
    targetUid: target,
    createdByUid: creator,
    groupId: '',
    title: id,
    localWallTime: '',
    timezone: 'Etc/UTC',
    scheduledInstantUtc: soon,
    status: status,
    outcome: outcome,
  );

  const done = ScheduleOutcome(result: OutcomeResult.done);

  group('which list a plan for someone else belongs to', () {
    test('open → Home; answered → Activity; cancelled → neither', () {
      final open = plan('open');
      final legacyPending = plan('pending', status: ScheduleItemStatus.pending);
      final answered = plan('answered', outcome: done);
      final lapsed = plan(
        'lapsed',
        outcome: const ScheduleOutcome(
          result: OutcomeResult.skipped,
          skipReason: 'Did not respond',
        ),
      );
      final cancelled = plan('cancelled', status: ScheduleItemStatus.withdrawn);

      expect(isOpenPlanForOthers(open, 'me'), isTrue);
      expect(isOpenPlanForOthers(legacyPending, 'me'), isTrue);
      for (final item in [answered, lapsed, cancelled]) {
        expect(isOpenPlanForOthers(item, 'me'), isFalse, reason: item.id);
      }
      expect(isSettledPlanForOthers(answered, 'me'), isTrue);
      expect(isSettledPlanForOthers(lapsed, 'me'), isTrue);
      expect(isSettledPlanForOthers(open, 'me'), isFalse);
      expect(isSettledPlanForOthers(cancelled, 'me'), isFalse);
    });

    test('self-plans and plans someone else made are never "for others"', () {
      final self = plan('self', target: 'me');
      final theirs = plan('theirs', creator: 'friend', target: 'me');
      for (final item in [self, theirs]) {
        expect(isOpenPlanForOthers(item, 'me'), isFalse);
        expect(isSettledPlanForOthers(item, 'me'), isFalse);
      }
    });
  });

  Widget host(
    Widget screen, {
    List<ScheduleItem> mine = const [],
    List<ScheduleItem> planned = const [],
  }) => ProviderScope(
    overrides: [
      currentUidProvider.overrideWithValue('me'),
      myItemsAsTargetProvider.overrideWithValue(AsyncData(mine)),
      myItemsAsPlannerProvider.overrideWithValue(AsyncData(planned)),
      myGroupsProvider.overrideWithValue(const AsyncData([])),
      profileByUidProvider.overrideWith(
        (ref, uid) => Stream.value(
          UserProfile(uid: uid, name: 'Name $uid', homeTimezone: 'Etc/UTC'),
        ),
      ),
    ],
    child: MaterialApp(theme: AppTheme.light, home: screen),
  );

  Future<void> expandAll(WidgetTester tester) async {
    for (final header in find.textContaining(' item').evaluate().toList()) {
      final text = (header.widget as Text).data ?? '';
      if (text.contains('· ')) {
        await tester.tap(find.byWidget(header.widget));
        await tester.pumpAndSettle();
      }
    }
  }

  testWidgets('Home shows my plan AND an open plan I set for a friend', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 4800);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        const OutcomeScreen(),
        mine: [plan('My walk', target: 'me', creator: 'friend')],
        planned: [
          plan('Their study'),
          plan('Their answered', outcome: done),
          plan('Their cancelled', status: ScheduleItemStatus.withdrawn),
        ],
      ),
    );
    await tester.pumpAndSettle();
    if (find.text('Their study').evaluate().isEmpty) await expandAll(tester);

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('My walk'), findsWidgets);
    expect(find.text('Their study'), findsOneWidget);
    expect(find.text('Their answered'), findsNothing);
    expect(find.text('Their cancelled'), findsNothing);
    // Only MY plan has Done/Skip; theirs has its planner card.
    expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
    expect(find.byType(PlannerItemCard), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-cancel-alarm')), findsOneWidget);
  });

  testWidgets('the hero band stays about MY next plan', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(const OutcomeScreen(), planned: [plan('Their study')]),
    );
    await tester.pumpAndSettle();
    if (find.byType(PlannerItemCard).evaluate().isEmpty) {
      await expandAll(tester);
    }
    // With no plan of my own the band shows its empty state, never theirs.
    expect(find.text('No upcoming plans.'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(PlannerItemCard),
        matching: find.text('Their study'),
      ),
      findsWidgets,
    );
  });

  testWidgets('Activity shows only answered plans for others', (tester) async {
    await tester.pumpWidget(
      host(
        const PlannerActivityScreen(),
        planned: [
          plan('Still open'),
          plan('Answered', outcome: done),
        ],
      ),
    );
    await tester.pumpAndSettle();
    if (find.text('Answered').evaluate().isEmpty) await expandAll(tester);
    expect(find.text('Answered'), findsOneWidget);
    expect(find.text('Still open'), findsNothing);
  });

  testWidgets('answering moves it from Home to Activity', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(const OutcomeScreen(), planned: [plan('Gym')]),
    );
    await tester.pumpAndSettle();
    if (find.text('Gym').evaluate().isEmpty) await expandAll(tester);
    expect(find.text('Gym'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      host(const OutcomeScreen(), planned: [plan('Gym', outcome: done)]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Gym'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      host(
        const PlannerActivityScreen(),
        planned: [plan('Gym', outcome: done)],
      ),
    );
    await tester.pumpAndSettle();
    if (find.text('Gym').evaluate().isEmpty) await expandAll(tester);
    expect(find.text('Gym'), findsOneWidget);
  });

  testWidgets('the Plan tab is called Home', (tester) async {
    await tester.pumpWidget(host(const PlanShell()));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('My Schedule'), findsNothing);
  });

  group('push taps land on the list that holds the plan', () {
    ProviderContainer routed(Map<String, dynamic> data) {
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
      );
      final container = ProviderContainer(
        overrides: [routerProvider.overrideWithValue(router)],
      );
      addTearDown(container.dispose);
      addTearDown(router.dispose);
      container.read(notificationRouterProvider).openForPushEvent(data);
      return container;
    }

    for (final event in [
      'unavailable',
      'dismissed',
      'voiceFallback',
      'voiceUndelivered',
    ]) {
      test('$event (still open) → Home, outlined', () {
        final intent = routed({
          'event': event,
          'itemId': 'x',
        }).read(planIntentProvider)!;
        expect(intent.itemId, 'x');
        expect(intent.activityItemId, isNull);
      });
    }

    test('outcome (answered) → Activity', () {
      final intent = routed({
        'event': 'outcome',
        'itemId': 'x',
      }).read(planIntentProvider)!;
      expect(intent.tab, PlanTab.activity);
      expect(intent.itemId, isNull);
    });
  });
}
