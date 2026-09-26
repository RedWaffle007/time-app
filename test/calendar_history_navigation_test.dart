import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/calendar/application/calendar_grouping.dart';
import 'package:time_app/features/calendar/presentation/calendar_item_sheet.dart';
import 'package:time_app/features/outcomes/presentation/history_screen.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  testWidgets('a decided Calendar plan routes to History and highlights it', (
    tester,
  ) async {
    final item = ScheduleItem(
      id: 'calendar-past',
      targetUid: 'me',
      createdByUid: 'me',
      groupId: '',
      title: 'Calendar past target',
      localWallTime: '',
      timezone: 'Etc/UTC',
      scheduledInstantUtc: DateTime.utc(2020, 1, 10, 9),
      status: ScheduleItemStatus.approved,
      outcome: const ScheduleOutcome(result: OutcomeResult.done),
    );
    final router = GoRouter(
      initialLocation: '/calendar',
      routes: [
        GoRoute(
          path: '/calendar',
          builder: (context, state) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showCalendarItemSheet(
                  context,
                  CalendarEntry(item: item, side: CalendarSide.mine),
                ),
                child: const Text('Show calendar plan'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/plan/history',
          builder: (context, state) => const HistoryScreen(),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myItemsAsTargetProvider.overrideWithValue(AsyncData([item])),
        ],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
    await tester.tap(find.text('Show calendar plan'));
    await tester.pumpAndSettle();
    expect(find.text('Open in History'), findsOneWidget);

    await tester.tap(find.text('Open in History'));
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(HistoryScreen).evaluate().isNotEmpty) break;
    }

    expect(router.routeInformationProvider.value.uri.path, '/plan/history');
    expect(find.text('History'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(HistoryScreen),
        matching: find.text('Calendar past target'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Calendar keeps pending, future, and planner ownership routing', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final cases = <(CalendarEntry, String)>[
      (
        CalendarEntry(
          item: _item(
            'pending',
            now.subtract(const Duration(days: 1)),
            status: ScheduleItemStatus.pending,
          ),
          side: CalendarSide.mine,
        ),
        // F2: there is no approvals queue; a legacy pending item is yours.
        'Open in My Schedule',
      ),
      (
        CalendarEntry(
          item: _item('future', now.add(const Duration(days: 1))),
          side: CalendarSide.mine,
        ),
        'Open in My Schedule',
      ),
      // Elapsed but undecided: its Done/Skip controls live in My Schedule.
      (
        CalendarEntry(
          item: _item('undecided', now.subtract(const Duration(minutes: 3))),
          side: CalendarSide.mine,
        ),
        'Open in My Schedule',
      ),
      (
        CalendarEntry(
          item: _item('planned', now.subtract(const Duration(days: 1))),
          side: CalendarSide.planned,
        ),
        'Open in Activity',
      ),
    ];

    for (final (entry, label) in cases) {
      await tester.pumpWidget(_sheetHost(entry));
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}

Widget _sheetHost(CalendarEntry entry) => ProviderScope(
  child: MaterialApp(
    theme: AppTheme.light,
    home: Builder(
      builder: (context) => Scaffold(
        body: FilledButton(
          onPressed: () => showCalendarItemSheet(context, entry),
          child: const Text('Show'),
        ),
      ),
    ),
  ),
);

ScheduleItem _item(
  String id,
  DateTime instant, {
  ScheduleItemStatus status = ScheduleItemStatus.approved,
}) => ScheduleItem(
  id: id,
  targetUid: 'me',
  createdByUid: 'me',
  groupId: '',
  title: id,
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: instant,
  status: status,
);
