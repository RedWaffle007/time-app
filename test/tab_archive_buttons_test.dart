import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/groups/application/group_providers.dart';
import 'package:time_app/features/groups/presentation/groups_screen.dart';
import 'package:time_app/features/outcomes/presentation/hero_band.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/presentation/planner_activity_screen.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:timezone/data/latest.dart' as tz_data;

/// 2026-09-28: every Plan sub-tab has the same top button row — Home:
/// CALENDAR · HISTORY · ARCHIVE; Activity: ARCHIVE; Groups: CREATE GROUP ·
/// JOIN GROUP · ARCHIVE — replacing the app bar's ⋮ → Archived and the
/// Groups icon buttons.
void main() {
  setUpAll(tz_data.initializeTimeZones);

  Future<void> pump(WidgetTester tester, Widget screen, {double width = 360}) {
    tester.view.physicalSize = Size(width * 3, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: screen),
        ),
        GoRoute(
          path: Routes.archived,
          builder: (_, _) => const Text('Archived screen'),
        ),
      ],
    );
    addTearDown(router.dispose);
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          myItemsAsTargetProvider.overrideWithValue(const AsyncData([])),
          myItemsAsPlannerProvider.overrideWithValue(const AsyncData([])),
          myGroupsProvider.overrideWithValue(const AsyncData([])),
        ],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
  }

  testWidgets('Home: CALENDAR · HISTORY · ARCHIVE at the very top', (
    tester,
  ) async {
    await pump(tester, const OutcomeScreen(embedded: true));
    await tester.pumpAndSettle();
    for (final label in ['CALENDAR', 'HISTORY', 'ARCHIVE']) {
      expect(find.widgetWithText(OutlinedButton, label), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(label)).dy,
        lessThan(tester.getTopLeft(find.byType(HeroBand)).dy),
        reason: '$label sits above the hero band',
      );
    }
    await tester.tap(find.byKey(const ValueKey('home-archive')));
    await tester.pumpAndSettle();
    expect(find.text('Archived screen'), findsOneWidget);
  });

  testWidgets('Activity: ARCHIVE opens Archived', (tester) async {
    await pump(tester, const PlannerActivityScreen(embedded: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('activity-archive')));
    await tester.pumpAndSettle();
    expect(find.text('Archived screen'), findsOneWidget);
  });

  testWidgets('Groups: CREATE GROUP · JOIN GROUP · ARCHIVE', (tester) async {
    await pump(tester, const GroupsScreen(embedded: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('groups-create')));
    await tester.pumpAndSettle();
    expect(find.text('New group'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('groups-join')));
    await tester.pumpAndSettle();
    expect(find.text('Join a group'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('groups-archive')));
    await tester.pumpAndSettle();
    expect(find.text('Archived screen'), findsOneWidget);
  });

  testWidgets('the Groups row wraps on a 320 px phone, never overflows', (
    tester,
  ) async {
    await pump(tester, const GroupsScreen(embedded: true), width: 320);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('ARCHIVE'), findsOneWidget);
  });

  test('the Plan app bar has no ⋮ and no Groups icon buttons', () {
    final shell = File(
      'lib/features/plan/presentation/plan_shell.dart',
    ).readAsStringSync();
    expect(shell, isNot(contains('PopupMenuButton')));
    expect(shell, isNot(contains("'Join by code'")));
    expect(shell, isNot(contains("'New group'")));
  });

  test('every ⋮ menu closes instantly (Motion.menu)', () {
    expect(Motion.menu.reverseDuration, Duration.zero);
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final src = file.readAsStringSync();
      final menus = 'PopupMenuButton<'.allMatches(src).length;
      final styled = 'popUpAnimationStyle: Motion.menu'.allMatches(src).length;
      expect(styled, menus, reason: file.path);
    }
  });
}
