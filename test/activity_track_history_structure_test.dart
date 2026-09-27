import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/planner_activity_screen.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  testWidgets('Activity keeps its explainer visible in the empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myItemsAsPlannerProvider.overrideWithValue(const AsyncData([])),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const PlannerActivityScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Plans you set for others, once answered.'),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Plans you set for others, once answered.'),
        matching: find.byType(Card),
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Plans you set for others appear here once they answer. '
        'Until then they are on Home.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Activity uses month categories as soon as two months exist', (
    tester,
  ) async {
    final items = [
      _plan('february-plan', DateTime.utc(2026, 2, 2, 9)),
      _plan('january-plan', DateTime.utc(2026, 1, 2, 9)),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('planner'),
          myItemsAsPlannerProvider.overrideWithValue(AsyncData(items)),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const PlannerActivityScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('February 2026 · 1 item'), findsOneWidget);
    expect(find.text('January 2026 · 1 item'), findsOneWidget);
  });
}

ScheduleItem _plan(String id, DateTime scheduled) => ScheduleItem(
  id: id,
  targetUid: 'target',
  createdByUid: 'planner',
  groupId: '',
  title: id,
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: scheduled,
  status: ScheduleItemStatus.approved,
  // Answered — Activity holds answered plans only (item 7).
  outcome: const ScheduleOutcome(result: OutcomeResult.done),
);
