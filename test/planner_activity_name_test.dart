import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/planner_activity_screen.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  testWidgets('Activity renders the planning target name in bold', (
    tester,
  ) async {
    tz_data.initializeTimeZones();
    final now = DateTime.now();
    final location = tz.getLocation('Asia/Kolkata');
    final scheduled = tz.TZDateTime(
      location,
      now.year,
      now.month,
      now.day,
      12,
    ).toUtc();
    final item = ScheduleItem(
      id: 'planned-item',
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: '',
      title: 'Morning walk',
      localWallTime: '12:00',
      timezone: 'Asia/Kolkata',
      scheduledInstantUtc: scheduled,
      status: ScheduleItemStatus.approved,
      alarm: ScheduleAlarmTimeline(
        rangAt: scheduled.add(const Duration(minutes: 1)),
        dismissedAt: scheduled.add(const Duration(minutes: 2)),
        unavailableAt: scheduled.add(const Duration(minutes: 3)),
      ),
    );
    const target = UserProfile(
      uid: 'target',
      name: 'Amina',
      homeTimezone: 'Asia/Kolkata',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myItemsAsPlannerProvider.overrideWithValue(AsyncData([item])),
          profileByUidProvider.overrideWith(
            (ref, uid) => Stream.value(uid == target.uid ? target : null),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const PlannerActivityScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final metadata = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan?.toPlainText().startsWith('for Amina ·') == true,
      ),
    );
    final root = metadata.textSpan! as TextSpan;
    final name = root.children![1] as TextSpan;

    expect(name.text, 'Amina');
    expect(name.style?.fontWeight, FontWeight.w700);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Morning walk'));
    await tester.pumpAndSettle();
    expect(find.text('Timeline'), findsOneWidget);
    expect(find.text('Scheduled'), findsOneWidget);
    expect(find.text('Outcome pending'), findsOneWidget);
    expect(find.text('Waiting for target'), findsOneWidget);
    expect(find.text('Rang'), findsOneWidget);
    expect(find.text('Dismissed'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('User unavailable at alarm time'),
      ),
      findsOneWidget,
    );
  });
}
