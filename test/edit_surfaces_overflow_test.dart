import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/core/widgets/time_backdrop.dart';
import 'package:time_app/features/applock/application/app_lock_providers.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/auth/presentation/profile_edit_screen.dart';
import 'package:time_app/features/calendar/application/calendar_grouping.dart';
import 'package:time_app/features/calendar/presentation/calendar_item_sheet.dart';
import 'package:time_app/features/home/presentation/you_screen.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/presentation/group_plan_sheet.dart';
import 'package:time_app/features/social/application/social_providers.dart';
import 'package:time_app/features/social/application/stats_providers.dart';
import 'package:time_app/features/time_tracking/presentation/log_time_sheet.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/stats/presentation/stats_screen.dart';

void main() {
  testWidgets('theme selector stays below its label at narrow widths', (
    tester,
  ) async {
    final profile = _profile();
    for (final scale in [1.0, 1.3]) {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        await _pump(
          tester,
          const YouScreen(),
          theme: theme,
          overrides: [
            profileProvider.overrideWith((ref) => Stream.value(profile)),
            incomingRequestCountProvider.overrideWithValue(0),
          ],
          scale: scale,
          height: 1000,
        );
        await tester.drag(find.byType(ListView), const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Theme'), findsOneWidget);
        expect(find.text('System'), findsOneWidget);
        final themeRect = tester.getRect(find.text('Theme'));
        final selectorRect = tester.getRect(
          find.byType(SegmentedButton<ThemeMode>),
        );
        final cardRect = tester.getRect(
          find.ancestor(
            of: find.byType(SegmentedButton<ThemeMode>),
            matching: find.byType(Card),
          ),
        );
        expect(selectorRect.top, greaterThan(themeRect.bottom));
        expect(
          selectorRect.width,
          closeTo(
            cardRect.width - Space.cardMargin.horizontal - Space.xxl,
            0.1,
          ),
        );
      }
    }
  });

  testWidgets('edit surfaces have no overflow at phone width', (tester) async {
    final item = _item();
    final profile = _profile();
    for (final scale in [1.0, 1.3]) {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        await _assertNoOverflow(
          tester,
          _launcher((context, ref) async {
            await showLogTimeSheet(context, ref);
          }),
          theme: theme,
          scale: scale,
        );
        await _assertNoOverflow(
          tester,
          _launcher((context, ref) async {
            await showGroupPlanSheet(
              context,
              ref,
              groupId: 'group',
              groupName: 'A very long group name',
              candidates: const [(uid: 'uid', isSelf: true)],
            );
          }),
          theme: theme,
          scale: scale,
        );
        await _assertNoOverflow(
          tester,
          _launcher((context, ref) async {
            await showCalendarItemSheet(
              context,
              CalendarEntry(item: item, side: CalendarSide.mine),
            );
          }),
          theme: theme,
          scale: scale,
        );
        await _assertNoOverflow(
          tester,
          const OutcomeScreen(),
          theme: theme,
          scale: scale,
          open: false,
          height: 1000,
          overrides: [
            myItemsAsTargetProvider.overrideWithValue(AsyncData([item])),
            appLockInitiallyEnabledProvider.overrideWithValue(false),
          ],
        );
        expect(tester.takeException(), isNull);
        await _assertNoOverflow(
          tester,
          const ProfileEditScreen(),
          theme: theme,
          scale: scale,
          overrides: [
            profileProvider.overrideWith((ref) => Stream.value(profile)),
            appLockInitiallyEnabledProvider.overrideWithValue(false),
          ],
          open: false,
        );
      }
    }
  });

  testWidgets('backdrop marks remain mounted and cached', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const TimeBackdrop(child: SizedBox.expand()),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(TimeBackdrop),
        matching: find.byType(RepaintBoundary),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(TimeBackdrop),
        matching: find.byKey(TimeBackdrop.painterKey),
      ),
      findsOneWidget,
    );
    expect(TimeBackdrop.lightMarkOpacity, 0.085);
    expect(TimeBackdrop.darkMarkOpacity, 0.10);
    expect(tester.takeException(), isNull);
  });

  testWidgets('StatsScreen renders computed values and honest placeholders', (
    tester,
  ) async {
    await _pump(
      tester,
      const StatsScreen(),
      overrides: [
        myComputedStatsProvider.overrideWithValue(
          const AsyncData({'tasksCompleted': 4, 'followThrough': 80}),
        ),
      ],
    );
    expect(find.text('Tasks completed'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('Coming soon'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

Widget _launcher(
  Future<void> Function(BuildContext context, WidgetRef ref) open,
) {
  return Scaffold(
    body: Consumer(
      builder: (context, ref, _) => FilledButton(
        onPressed: () => open(context, ref),
        child: const Text('Open surface'),
      ),
    ),
  );
}

Future<void> _assertNoOverflow(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double scale = 1.0,
  List<dynamic> overrides = const [],
  bool open = true,
  double height = 640,
}) async {
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await _pump(
      tester,
      child,
      theme: theme,
      scale: scale,
      height: height,
      overrides: overrides,
    );
    if (open) {
      await tester.tap(find.text('Open surface'));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
    expect(
      errors.where((error) => error.exceptionAsString().contains('overflowed')),
      isEmpty,
    );
  } finally {
    FlutterError.onError = previous;
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double scale = 1.0,
  List<dynamic> overrides = const [],
  double height = 640,
}) async {
  tester.view.physicalSize = Size(320 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides.cast(),
      child: MaterialApp(
        key: UniqueKey(),
        theme: theme ?? AppTheme.light,
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

UserProfile _profile() => const UserProfile(
  uid: 'uid',
  name: 'Profile name',
  homeTimezone: 'UTC',
  username: 'profile_name',
  quietHoursStartMinutes: 22 * 60,
  quietHoursEndMinutes: 7 * 60,
);

ScheduleItem _item() {
  final instant = DateTime.now().toUtc();
  return ScheduleItem(
    id: 'item',
    targetUid: 'uid',
    createdByUid: 'uid',
    groupId: 'group',
    title: 'A task with a long title',
    localWallTime: 'now',
    timezone: 'UTC',
    scheduledInstantUtc: instant,
    status: ScheduleItemStatus.approved,
  );
}
