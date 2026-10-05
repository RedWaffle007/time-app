import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/reminders/application/missed_alarm_providers.dart';
import 'package:time_app/features/reminders/presentation/missed_button.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

import 'support/missed_alarm_fakes.dart';

/// 🔔 Missed on the Plan header (2026-10-05, UI-RULES §6.16a).
void main() {
  ScheduleItem rung(String id) => ScheduleItem(
    id: id,
    targetUid: 'me',
    createdByUid: 'planner',
    groupId: '',
    title: 'Task $id',
    localWallTime: '',
    timezone: 'Etc/UTC',
    scheduledInstantUtc: DateTime.utc(2026, 9, 23, 8),
    status: ScheduleItemStatus.approved,
    alarm: ScheduleAlarmTimeline(rangAt: DateTime.utc(2026, 9, 23, 8), ring: 1),
  );

  Future<ProviderContainer> pump(
    WidgetTester tester,
    List<ScheduleItem> items,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          ...missedAlarmsWith(items),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Plan'),
              actions: const [MissedButton()],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.text('Plan')));
  }

  testWidgets('always there, with the word Missed and the count of '
      'alarms waiting', (tester) async {
    await pump(tester, [rung('a'), rung('b')]);
    expect(find.text('Missed'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('a tap opens the Missed pop-up', (tester) async {
    final container = await pump(tester, [rung('a')]);
    final before = container.read(missedPopupTriggerProvider);
    await tester.tap(find.byKey(const ValueKey('missed-button')));
    await tester.pump();
    expect(container.read(missedPopupTriggerProvider), before + 1);
  });

  testWidgets('with nothing waiting: no badge, and a tap says so instead of '
      'opening an empty pop-up', (tester) async {
    final container = await pump(tester, const []);
    expect(find.text('Missed'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('missed-button')));
    await tester.pump();
    expect(find.text('Nothing missed'), findsOneWidget);
    expect(container.read(missedPopupTriggerProvider), 0);
  });
}
