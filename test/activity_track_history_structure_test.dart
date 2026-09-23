import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/planner_activity_screen.dart';
import 'package:time_app/features/time_tracking/application/time_tracking_providers.dart';
import 'package:time_app/features/time_tracking/domain/tracked_entry.dart';
import 'package:time_app/features/time_tracking/presentation/track_screen.dart';
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

    expect(find.text('Plans you make for others.'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Plans you make for others.'),
        matching: find.byType(Card),
      ),
      findsOneWidget,
    );
    expect(
      find.text("You haven't planned anything for anyone yet."),
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

  testWidgets('Track keeps its explainer visible in the empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myTrackedEntriesProvider.overrideWithValue(const AsyncData([])),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const TrackScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Track the time you spend.'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Track the time you spend.'),
        matching: find.byType(Card),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining("You haven't logged any time yet."),
      findsOneWidget,
    );
  });

  testWidgets('Track uses month categories as soon as two months exist', (
    tester,
  ) async {
    final entries = [
      TrackedEntry(
        id: 'february-entry',
        taskName: 'February work',
        durationMinutes: 30,
        logDate: '2026-02-02',
      ),
      TrackedEntry(
        id: 'january-entry',
        taskName: 'January work',
        durationMinutes: 30,
        logDate: '2026-01-02',
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myTrackedEntriesProvider.overrideWithValue(AsyncData(entries)),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const TrackScreen()),
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
);
