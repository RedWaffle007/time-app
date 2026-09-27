import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/stats/application/my_stats.dart';
import 'package:time_app/features/stats/application/my_stats_providers.dart';
import 'package:time_app/features/stats/presentation/stats_screen.dart';

import 'fixtures/my_stats_fixture.dart';

/// The Stats page (item 24b, UI-RULES §6.14).
void main() {
  Widget harness(
    MyStats stats, {
    ThemeData? theme,
    Locale locale = const Locale('en'),
  }) => ProviderScope(
    overrides: [
      myStatsProvider.overrideWithValue(AsyncData(stats)),
      profileByUidProvider.overrideWith(
        (ref, uid) => Stream.value(
          UserProfile(
            uid: uid,
            name: uid == 'p1' ? 'Test Planner' : 'Second Planner',
            homeTimezone: 'UTC',
          ),
        ),
      ),
    ],
    child: MaterialApp(
      theme: theme ?? AppTheme.light,
      locale: locale,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('en'), Locale('bn')],
      home: const StatsScreen(),
    ),
  );

  Future<void> pumpTall(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(360 * 3, 2400 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  testWidgets('renders every section with its numbers', (tester) async {
    await pumpTall(
      tester,
      harness(
        sampleMyStats(
          topPlanners: const [
            PlannerCount(uid: 'p1', count: 9),
            PlannerCount(uid: 'p2', count: 6),
          ],
        ),
      ),
    );
    expect(find.text('Last 7 days'), findsOneWidget);
    expect(find.text('12'), findsWidgets); // hero + this week's bar
    expect(find.text('2 skipped · 1 missed'), findsOneWidget);
    expect(find.text('3 more done than the week before.'), findsOneWidget);
    for (final h in [
      'Showing up',
      'From your people',
      'Planning for others',
      'Last 8 weeks',
    ]) {
      expect(find.text(h), findsOneWidget, reason: h);
    }
    expect(find.text('86%'), findsOneWidget);
    expect(find.text('Set for you 90% · Self 80%'), findsOneWidget);
    expect(find.text('92%'), findsOneWidget);
    expect(find.text('4 days'), findsOneWidget);
    expect(find.text('11 days'), findsOneWidget);
    expect(find.text('23'), findsOneWidget);
    expect(find.text('Test Planner'), findsOneWidget);
    expect(find.text('Second Planner'), findsOneWidget);
    expect(find.text('Only you can see this.'), findsOneWidget);
    expect(find.text('out of 7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a percentage below the sample says why, never 0%', (
    tester,
  ) async {
    await pumpTall(tester, harness(sampleMyStats()));
    // alarmsSetCompletion is null in the fixture.
    expect(find.text('After 5 answered plans'), findsOneWidget);
    expect(find.text('0%'), findsNothing);
  });

  testWidgets('no top-planner card when nobody planned for you', (
    tester,
  ) async {
    await pumpTall(tester, harness(sampleMyStats()));
    expect(find.text('Most plans from'), findsNothing);
  });

  testWidgets('empty record shows the empty state', (tester) async {
    await pumpTall(tester, harness(sampleMyStats(empty: true)));
    expect(find.textContaining('No plans yet'), findsOneWidget);
    expect(find.text('Showing up'), findsNothing);
  });

  testWidgets('week bars state every number for screen readers', (
    tester,
  ) async {
    await pumpTall(tester, harness(sampleMyStats()));
    final handle = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp(r'^Plans done per week: .*this week 12$')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('dark theme renders without exceptions', (tester) async {
    await pumpTall(tester, harness(sampleMyStats(), theme: AppTheme.dark));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a locale with its own numerals renders them in the hero', (
    tester,
  ) async {
    await pumpTall(
      tester,
      harness(sampleMyStats(), locale: const Locale('bn')),
    );
    final twelve = NumberFormat.decimalPattern('bn').format(12);
    expect(twelve, isNot('12'), reason: 'fixture assumes bn has own numerals');
    expect(find.text(twelve), findsWidgets);
    expect(find.text('86%'), findsNothing);
  });
}
