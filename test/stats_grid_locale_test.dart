import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/social/application/stats_registry.dart';
import 'package:time_app/features/social/domain/profile_stat.dart';
import 'package:time_app/features/social/presentation/stats_section.dart';

/// Stat tiles render every number through the locale (worldwide requirement,
/// UI-RULES §6.14, item 24a) — never `'$value'`, which is Latin digits
/// everywhere. `bn` is the probe because it writes its own numerals (intl's
/// `ar` data uses Latin digits, which would pass vacuously).
void main() {
  const stats = [
    ProfileStat(
      key: 'tasksCompleted',
      label: 'Tasks completed',
      unit: ProfileStatUnit.count,
      state: ProfileStatState.ready,
      value: 42,
    ),
    ProfileStat(
      key: 'followThrough',
      label: 'Follow-through',
      unit: ProfileStatUnit.percent,
      state: ProfileStatState.ready,
      value: 86,
    ),
    ProfileStat(
      key: 'currentStreak',
      label: 'Current streak',
      unit: ProfileStatUnit.days,
      state: ProfileStatState.ready,
      value: 7,
    ),
  ];

  Widget harness(Locale locale) => MaterialApp(
    theme: AppTheme.light,
    locale: locale,
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('en'), Locale('bn')],
    home: const Scaffold(body: StatsGrid(stats: stats)),
  );

  testWidgets('English renders plain digits and a percent sign', (
    tester,
  ) async {
    await tester.pumpWidget(harness(const Locale('en')));
    expect(find.text('42'), findsOneWidget);
    expect(find.text('86%'), findsOneWidget);
    expect(find.text('7 days'), findsOneWidget);
  });

  testWidgets('a locale with its own numerals renders them', (tester) async {
    final count = NumberFormat.decimalPattern('bn').format(42);
    // Guard the guard: the fixture only proves something if bn differs.
    expect(count, isNot('42'), reason: 'fixture assumes bn has own numerals');

    await tester.pumpWidget(harness(const Locale('bn')));
    expect(find.text(count), findsOneWidget);
    expect(
      find.text(NumberFormat.percentPattern('bn').format(0.86)),
      findsOneWidget,
    );
    expect(
      find.text('${NumberFormat.decimalPattern('bn').format(7)} days'),
      findsOneWidget,
    );
    expect(find.text('42'), findsNothing);
  });

  testWidgets('a visitor sees follow-through withheld below the sample', (
    tester,
  ) async {
    // Item 24c: a profile published without `followThrough` (fewer than five
    // answered plans) must read as "not enough yet", never 0% or a
    // "Coming soon" feature tile.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: StatsGrid(
            stats: statsFromSnapshot(
              const ProfileStatsSnapshot(
                values: {
                  'tasksCompleted': 3,
                  'currentStreak': 2,
                  'bestStreak': 5,
                },
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Follow-through'), findsOneWidget);
    expect(find.text('After 5 answered plans'), findsOneWidget);
    expect(find.text('0%'), findsNothing);
    expect(find.text('Coming soon'), findsNothing);
    expect(find.text('5 days'), findsOneWidget);
  });
}
