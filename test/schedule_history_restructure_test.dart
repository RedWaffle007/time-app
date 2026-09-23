import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  testWidgets('My Schedule shows only Upcoming with Calendar and History', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final upcoming = _item('upcoming', now.add(const Duration(days: 1)));
    final elapsed = _item('elapsed', now.subtract(const Duration(days: 1)));

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
        _item('old', DateTime.now().toUtc().subtract(const Duration(days: 1))),
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

  testWidgets('History becomes month-grouped at two distinct months', (
    tester,
  ) async {
    final items = [
      _item('February plan', DateTime.utc(2020, 2, 20, 9)),
      _item('January plan', DateTime.utc(2020, 1, 10, 9)),
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
        _item('First', DateTime.utc(2020, 2, 20, 9)),
        _item('Second', DateTime.utc(2020, 2, 10, 9)),
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
        _item(
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
    final target = _item('Warm history target', DateTime.utc(2020, 2, 20, 9));
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
}

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
