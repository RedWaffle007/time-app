import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/groups/application/group_providers.dart';
import 'package:time_app/features/home/presentation/you_screen.dart';
import 'package:time_app/features/outcomes/presentation/history_screen.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/plan/presentation/plan_shell.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/social/application/social_providers.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  testWidgets('My Schedule shows undecided plans, Calendar and History', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final upcoming = _item('upcoming', now.add(const Duration(days: 1)));
    final elapsed = _decided('elapsed', now.subtract(const Duration(days: 1)));

    await tester.pumpWidget(_host(const OutcomeScreen(), [upcoming, elapsed]));
    await tester.pumpAndSettle();

    expect(find.text('Upcoming Plans'), findsOneWidget);
    expect(find.text('CALENDAR'), findsOneWidget);
    expect(find.text('HISTORY'), findsOneWidget);
    expect(find.text('Today'), findsNothing);
    expect(find.text('Future plans'), findsNothing);
    expect(find.text('Past plans'), findsNothing);
    final calendarButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'CALENDAR'),
    );
    expect(
      calendarButton.style?.textStyle?.resolve({})?.fontWeight,
      FontWeight.bold,
    );
    expect(
      calendarButton.style?.shape?.resolve({}),
      isA<RoundedRectangleBorder>(),
    );

    await tester.tap(find.textContaining('· 1 item').first);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(Card), matching: find.text('upcoming')),
      findsOneWidget,
    );
    expect(find.text('elapsed'), findsNothing);

    expect(
      tester.getCenter(find.text('CALENDAR')).dx,
      lessThan(tester.getCenter(find.text('HISTORY')).dx),
    );
  });

  testWidgets('empty Upcoming retains both navigation controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const OutcomeScreen(), [
        _decided(
          'old',
          DateTime.now().toUtc().subtract(const Duration(days: 1)),
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('No upcoming plans.'), findsOneWidget);
    expect(find.text('CALENDAR'), findsOneWidget);
    expect(find.text('HISTORY'), findsOneWidget);
  });

  testWidgets('superseded Calendar icon and You entry are removed', (
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
    expect(find.byTooltip('Calendar'), findsNothing);
    expect(find.text('CALENDAR'), findsOneWidget);

    // Unmount the first ProviderScope before installing one with a different
    // override set; Riverpod deliberately rejects changing override count on
    // an existing scope element.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileProvider.overrideWith((ref) => Stream.value(null)),
          incomingRequestCountProvider.overrideWithValue(0),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const YouScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Calendar'), findsNothing);
  });

  testWidgets(
    'bold rounded PLAN button persists across all Plan tabs and routes',
    (tester) async {
      final router = GoRouter(
        initialLocation: Routes.plan,
        routes: [
          GoRoute(
            path: Routes.plan,
            builder: (context, state) => const PlanShell(),
            routes: [
              GoRoute(
                path: 'schedule-builder',
                builder: (context, state) =>
                    const Scaffold(body: Text('Schedule builder destination')),
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            myItemsAsTargetProvider.overrideWithValue(const AsyncData([])),
            myItemsAsPlannerProvider.overrideWithValue(const AsyncData([])),
            myGroupsProvider.overrideWithValue(const AsyncData([])),
          ],
          child: MaterialApp.router(
            theme: AppTheme.light,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      void expectPlanButton() {
        expect(find.text('PLAN'), findsOneWidget);
        expect(find.byTooltip('Plan an item'), findsOneWidget);
        final fab = tester.widget<FloatingActionButton>(
          find.byType(FloatingActionButton),
        );
        expect(fab.isExtended, isTrue);
        expect(fab.heroTag, 'planCreateFab');
        final label = tester.widget<Text>(find.text('PLAN'));
        expect(label.style?.fontWeight, FontWeight.bold);
        final shape = Theme.of(
          tester.element(find.byType(FloatingActionButton)),
        ).floatingActionButtonTheme.shape;
        expect(shape, isA<RoundedRectangleBorder>());
        expect((shape! as RoundedRectangleBorder).borderRadius, Radii.pill);
      }

      expectPlanButton();
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      expectPlanButton();
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      expectPlanButton();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('Schedule builder destination'), findsOneWidget);
    },
  );

  testWidgets('History becomes month-grouped at two distinct months', (
    tester,
  ) async {
    final items = [
      _decided('February plan', DateTime.utc(2020, 2, 20, 9)),
      _decided('January plan', DateTime.utc(2020, 1, 10, 9)),
      _item(
        'Completed future plan',
        DateTime.now().toUtc().add(const Duration(days: 30)),
        outcome: const ScheduleOutcome(result: OutcomeResult.done),
      ),
    ];
    await tester.pumpWidget(_host(const HistoryScreen(), items));
    await tester.pumpAndSettle();

    expect(find.text('Past Plans'), findsOneWidget);
    expect(find.text('February 2020 · 1 item'), findsOneWidget);
    expect(find.text('January 2020 · 1 item'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('February 2020 · 1 item')).dy,
      lessThan(tester.getTopLeft(find.text('January 2020 · 1 item')).dy),
    );
    expect(find.text('February plan'), findsNothing);

    await tester.tap(find.text('February 2020 · 1 item'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Feb 20, 2020 · 1 item'));
    await tester.pumpAndSettle();
    expect(find.text('February plan'), findsOneWidget);
  });

  testWidgets('one-month History remains directly day-grouped', (tester) async {
    await tester.pumpWidget(
      _host(const HistoryScreen(), [
        _decided('First', DateTime.utc(2020, 2, 20, 9)),
        _decided('Second', DateTime.utc(2020, 2, 10, 9)),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('February 2020 · 2 items'), findsNothing);
    expect(find.textContaining('Feb 20, 2020 · 1 item'), findsOneWidget);
    expect(find.textContaining('Feb 10, 2020 · 1 item'), findsOneWidget);
  });

  testWidgets('cold History highlight expands month/day and reveals far item', (
    tester,
  ) async {
    const targetId = 'far-history';
    const targetTitle = 'Far history target';
    final items = [
      for (var index = 0; index < 70; index++)
        _decided(
          index == 10 ? targetTitle : 'Old plan $index',
          DateTime.utc(2020, 1, 1).add(Duration(days: index)),
          id: index == 10 ? targetId : 'old-$index',
        ),
    ];
    await tester.pumpWidget(
      _host(
        const HistoryScreen(highlightItemId: targetId, highlightToken: 1),
        items,
      ),
    );
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.text(targetTitle).evaluate().isNotEmpty) break;
    }

    expect(find.text(targetTitle), findsOneWidget);
    final card = tester.widget<Card>(
      find.ancestor(of: find.text(targetTitle), matching: find.byType(Card)),
    );
    final shape = card.shape! as RoundedRectangleBorder;
    expect(shape.side.width, Sizes.ruleWidth);
    expect(tester.takeException(), isNull);
  });

  testWidgets('warm History highlight expands a previously collapsed day', (
    tester,
  ) async {
    final target = _decided(
      'Warm history target',
      DateTime.utc(2020, 2, 20, 9),
    );
    String? highlight;
    var token = 0;
    late StateSetter updateHost;

    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return HistoryScreen(
              highlightItemId: highlight,
              highlightToken: token,
            );
          },
        ),
        [target],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Warm history target'), findsNothing);

    updateHost(() {
      highlight = target.id;
      token++;
    });
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.text('Warm history target').evaluate().isNotEmpty) break;
    }

    expect(find.text('Warm history target'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an elapsed undecided plan stays in My Schedule with Done/Skip, not History',
    (tester) async {
      // Regression (2026-09-25): an alarm dismissed with the power button left
      // the plan in Past Plans, where it could no longer be marked Done/Skip.
      final dismissed = _item(
        'Dismissed alarm',
        DateTime.now().toUtc().subtract(const Duration(minutes: 3)),
      );

      await tester.pumpWidget(_host(const OutcomeScreen(), [dismissed]));
      await tester.pumpAndSettle();
      if (find.text('Dismissed alarm').evaluate().isEmpty) {
        await tester.tap(find.textContaining('· 1 item').first);
        await tester.pumpAndSettle();
      }

      expect(find.text('No upcoming plans.'), findsNothing);
      expect(find.text('Dismissed alarm'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Skip'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(_host(const HistoryScreen(), [dismissed]));
      await tester.pumpAndSettle();
      expect(find.text('Dismissed alarm'), findsNothing);
    },
  );

  testWidgets('a decision moves the same plan from My Schedule to History', (
    tester,
  ) async {
    final instant = DateTime.now().toUtc().subtract(const Duration(minutes: 3));
    final decided = _item(
      'Decided plan',
      instant,
      outcome: const ScheduleOutcome(result: OutcomeResult.skipped),
    );

    await tester.pumpWidget(_host(const OutcomeScreen(), [decided]));
    await tester.pumpAndSettle();
    expect(find.text('No upcoming plans.'), findsOneWidget);
    expect(find.text('Decided plan'), findsNothing);
  });
}

/// History holds DECIDED plans only (2026-09-25): elapsed time alone never
/// moves a plan there.
ScheduleItem _decided(String title, DateTime instant, {String? id}) => _item(
  title,
  instant,
  id: id,
  outcome: const ScheduleOutcome(result: OutcomeResult.done),
);

Widget _host(Widget screen, List<ScheduleItem> items) => ProviderScope(
  overrides: [
    myItemsAsTargetProvider.overrideWithValue(AsyncData(items)),
    profileByUidProvider.overrideWith((ref, uid) => Stream.value(null)),
  ],
  child: MaterialApp(theme: AppTheme.light, home: screen),
);

ScheduleItem _item(
  String title,
  DateTime instant, {
  String? id,
  ScheduleOutcome? outcome,
}) => ScheduleItem(
  id: id ?? title,
  targetUid: 'me',
  createdByUid: 'me',
  groupId: '',
  title: title,
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: instant,
  status: ScheduleItemStatus.approved,
  outcome: outcome,
);
