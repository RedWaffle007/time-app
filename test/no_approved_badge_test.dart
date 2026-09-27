import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/status_style.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// 2026-09-27: live alarms show no "Approved" badge (no approval step since
/// F2); answered and other states keep theirs.
void main() {
  ScheduleItem item({
    ScheduleItemStatus status = ScheduleItemStatus.approved,
    ScheduleOutcome? outcome,
  }) => ScheduleItem(
    id: 'i',
    targetUid: 't',
    createdByUid: 'p',
    groupId: '',
    title: 'Run',
    localWallTime: '',
    timezone: 'UTC',
    scheduledInstantUtc: DateTime.utc(2030),
    status: status,
    outcome: outcome,
  );

  Future<void> pump(WidgetTester t, ScheduleItem i) => t.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Builder(builder: (context) => itemStatusBadge(i, context)),
      ),
    ),
  );

  testWidgets('a live alarm shows no badge', (t) async {
    await pump(t, item());
    expect(find.text('Approved'), findsNothing);
    expect(find.byType(StatusBadge), findsNothing);
  });

  testWidgets('an answered alarm shows its outcome', (t) async {
    await pump(
      t,
      item(outcome: const ScheduleOutcome(result: OutcomeResult.done)),
    );
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('a cancelled plan still says so', (t) async {
    await pump(t, item(status: ScheduleItemStatus.withdrawn));
    expect(find.text('Withdrawn'), findsOneWidget);
  });
}
