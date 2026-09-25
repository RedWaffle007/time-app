import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/groups/application/group_providers.dart';
import 'package:time_app/features/groups/domain/planner_grant.dart';
import 'package:time_app/features/outcomes/presentation/history_screen.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/plan/application/plan_intent.dart';
import 'package:time_app/features/plan/presentation/plan_shell.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/planner_activity_screen.dart';
import 'package:time_app/features/social/application/social_providers.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:timezone/data/latest.dart' as tz_data;

/// Regressions from the second 2026-09-25 device pass. Each group names the
/// report it guards so a failure reads as the bug it would reintroduce.
void main() {
  setUpAll(tz_data.initializeTimeZones);

  group('status timeline on My Schedule and History cards', () {
    testWidgets('tapping an upcoming card opens its timeline', (tester) async {
      final item = _item(
        'Upcoming walk',
        DateTime.now().toUtc().add(const Duration(hours: 2)),
        createdByUid: 'planner',
      );
      await tester.pumpWidget(_host(const OutcomeScreen(), [item]));
      await tester.pumpAndSettle();
      await _expandIfCollapsed(tester, 'Upcoming walk');

      // The hero band also shows the next plan's title; tap the CARD.
      await tester.tap(
        find.byKey(const ValueKey('outcome-card-Upcoming walk')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Timeline'), findsOneWidget);
      expect(find.text('Planned by Amina · Etc/UTC'), findsOneWidget);
    });

    testWidgets('a past plan in History shows its status timeline too', (
      tester,
    ) async {
      final at = DateTime.utc(2020, 2, 20, 9);
      final item = ScheduleItem(
        id: 'past',
        targetUid: 'me',
        createdByUid: 'planner',
        groupId: '',
        title: 'Past walk',
        localWallTime: '',
        timezone: 'Etc/UTC',
        scheduledInstantUtc: at,
        status: ScheduleItemStatus.approved,
        outcome: ScheduleOutcome(
          result: OutcomeResult.skipped,
          skippedAt: at.add(const Duration(minutes: 2)),
          skipReason: kUserUnavailableSkipReason,
        ),
        alarm: ScheduleAlarmTimeline(
          rangAt: at,
          unavailableAt: at.add(const Duration(minutes: 1)),
        ),
      );
      await tester.pumpWidget(_host(const HistoryScreen(), [item]));
      await tester.pumpAndSettle();
      await _expandIfCollapsed(tester, 'Past walk');

      await tester.tap(find.byKey(const ValueKey('outcome-card-past')));
      await tester.pumpAndSettle();

      expect(find.text('Timeline'), findsOneWidget);
      expect(find.text('User unavailable at alarm time'), findsWidgets);
    });

    testWidgets('Done on a card records Done, not the timeline', (
      tester,
    ) async {
      final item = _item(
        'Card with buttons',
        DateTime.now().toUtc().add(const Duration(hours: 2)),
      );
      await tester.pumpWidget(_host(const OutcomeScreen(), [item]));
      await tester.pumpAndSettle();
      await _expandIfCollapsed(tester, 'Card with buttons');

      await tester.tap(find.widgetWithText(OutlinedButton, 'Skip'));
      await tester.pumpAndSettle();

      expect(find.text('Timeline'), findsNothing);
      expect(find.text('Skip this?'), findsOneWidget);
    });
  });

  group('Calendar → Open in Activity lands on the exact plan', () {
    testWidgets('a far Activity item is revealed and outlined', (tester) async {
      final now = DateTime.now().toUtc();
      const targetTitle = 'Far planned target';
      final items = [
        for (var index = 0; index < 60; index++)
          _item(
            index == 45 ? targetTitle : 'Planned $index',
            now.subtract(Duration(days: index)),
            id: index == 45 ? 'far' : 'p$index',
            targetUid: 'friend',
            createdByUid: 'me',
          ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            myItemsAsPlannerProvider.overrideWithValue(AsyncData(items)),
            profileByUidProvider.overrideWith((ref, uid) => Stream.value(null)),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const PlannerActivityScreen(
              highlightItemId: 'far',
              highlightToken: 1,
            ),
          ),
        ),
      );
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.text(targetTitle).evaluate().isNotEmpty) break;
      }

      expect(find.text(targetTitle), findsOneWidget);
      final card = tester.widget<Card>(
        find.ancestor(of: find.text(targetTitle), matching: find.byType(Card)),
      );
      expect(
        (card.shape! as RoundedRectangleBorder).side.width,
        Sizes.ruleWidth,
      );
      expect(tester.takeException(), isNull);
    });

    test('the intent carries the item and the Activity tab', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(planIntentProvider.notifier).highlightActivityItem('x');
      final intent = container.read(planIntentProvider)!;

      expect(intent.tab, PlanTab.activity);
      expect(intent.activityItemId, 'x');
      expect(intent.itemId, isNull, reason: 'must not force My Schedule');
    });
  });

  testWidgets('the PLAN button sits bottom-LEFT, clear of the Done buttons', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myItemsAsTargetProvider.overrideWithValue(const AsyncData([])),
          myItemsAsPlannerProvider.overrideWithValue(const AsyncData([])),
          myGroupsProvider.overrideWithValue(const AsyncData([])),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const PlanShell()),
      ),
    );
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(
      find
          .ancestor(
            of: find.byType(FloatingActionButton),
            matching: find.byType(Scaffold),
          )
          .first,
    );
    expect(
      scaffold.floatingActionButtonLocation,
      FloatingActionButtonLocation.startFloat,
    );
    final screenWidth = tester.getSize(find.byType(PlanShell)).width;
    expect(
      tester.getCenter(find.byType(FloatingActionButton)).dx,
      lessThan(screenWidth / 2),
    );
  });

  group('names, never ids', () {
    test('profiles of every planning target are prefetched from sign-in', () {
      final watched = <String>[];
      final container = ProviderContainer(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          effectivePlanningTargetsProvider.overrideWithValue(
            const AsyncData([
              PlannerGrant(
                plannerUid: 'me',
                targetUid: 'friend-a',
                groupId: '',
                granted: true,
              ),
              PlannerGrant(
                plannerUid: 'me',
                targetUid: 'friend-b',
                groupId: '',
                granted: true,
              ),
            ]),
          ),
          profileByUidProvider.overrideWith((ref, uid) {
            watched.add(uid);
            return const Stream<UserProfile?>.empty();
          }),
        ],
      );
      addTearDown(container.dispose);

      container.read(planningTargetProfilesPrefetchProvider);

      expect(watched.toSet(), {'me', 'friend-a', 'friend-b'});
    });

    test('the loading label is not an id', () {
      expect(kProfileNameLoading, 'Loading…');
    });
  });

  group('alarm cold start', () {
    test('an alarm initial route opens the alarm directly', () {
      expect(
        alarmLaunchLocation('/alarm?item=item-a'),
        Routes.alarmForItem('item-a'),
      );
      expect(
        alarmLaunchLocation('/alarm?item=a%2Fb+c'),
        Routes.alarmForItem('a/b c'),
      );
    });

    test('an ordinary launch is not an alarm launch', () {
      expect(alarmLaunchLocation('/'), isNull);
      expect(alarmLaunchLocation('/alarm'), isNull);
      expect(alarmLaunchLocation('/alarm?item='), isNull);
      expect(alarmLaunchLocation('/plan?item=x'), isNull);
    });
  });
}

Future<void> _expandIfCollapsed(WidgetTester tester, String title) async {
  if (find.text(title).evaluate().isNotEmpty) return;
  await tester.tap(find.textContaining('· 1 item').last);
  await tester.pumpAndSettle();
}

Widget _host(Widget screen, List<ScheduleItem> items) => ProviderScope(
  overrides: [
    myItemsAsTargetProvider.overrideWithValue(AsyncData(items)),
    profileByUidProvider.overrideWith(
      (ref, uid) => Stream.value(
        uid == 'planner'
            ? const UserProfile(
                uid: 'planner',
                name: 'Amina',
                homeTimezone: 'Etc/UTC',
              )
            : null,
      ),
    ),
  ],
  child: MaterialApp(theme: AppTheme.light, home: screen),
);

ScheduleItem _item(
  String title,
  DateTime instant, {
  String? id,
  String targetUid = 'me',
  String createdByUid = 'me',
}) => ScheduleItem(
  id: id ?? title,
  targetUid: targetUid,
  createdByUid: createdByUid,
  groupId: '',
  title: title,
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: instant,
  status: ScheduleItemStatus.approved,
);
