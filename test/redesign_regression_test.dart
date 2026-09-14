import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/core/widgets/accent_card.dart';
import 'package:time_app/core/widgets/section_header.dart';
import 'package:time_app/features/stats/presentation/stats_screen.dart';
import 'package:time_app/features/social/application/stats_providers.dart';
import 'package:time_app/features/social/domain/profile_stat.dart';
import 'package:time_app/features/social/presentation/stats_section.dart';

/// Regression guards for the CHECKMATE redesign. Each pumps a real widget under
/// the real theme and fails on any layout overflow or thrown exception — the two
/// bug classes the redesign introduced (an empty Stats screen; an overflow
/// hazard stripe on other screens).
void main() {
  Widget host(Widget child) =>
      MaterialApp(theme: AppTheme.light, darkTheme: AppTheme.dark, home: child);

  testWidgets('AccentCard renders in an unbounded-height context (Wrap)', (
    tester,
  ) async {
    // This is exactly how StatsScreen uses it: a fixed-width SizedBox in a Wrap,
    // i.e. bounded width but UNBOUNDED height. A Row with CrossAxisAlignment
    // .stretch throws here unless the rail is height-constrained.
    await tester.pumpWidget(
      host(
        Scaffold(
          body: Wrap(
            children: [
              SizedBox(
                width: 160,
                child: AccentCard(
                  accent: const Color(0xFF1B7A3D),
                  child: const Padding(
                    padding: EdgeInsets.all(Space.md),
                    child: Text('Tile body'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Tile body'), findsOneWidget);
    // The coloured rail must have real height, not collapse to zero.
    final railSize = tester.getSize(find.byType(ColoredBox).first);
    expect(railSize.height, greaterThan(0));
  });

  testWidgets('SectionHeader renders with a categorical accent', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const Scaffold(body: SectionHeader('Your numbers'))),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Your numbers'), findsOneWidget);
  });

  testWidgets('StatsScreen shows its content, not an empty/broken screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myComputedStatsProvider.overrideWithValue(
            const AsyncData({
              'tasksCompleted': 3,
              'followThrough': 75,
            }),
          ),
        ],
        child: host(const StatsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The screen must actually render its tiles and copy.
    expect(find.text('Stats'), findsOneWidget);
    expect(find.text('Tasks completed'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('Coming soon'), findsWidgets);
    // Em-dash placeholder values present.
    expect(find.text('—'), findsWidgets);
  });

  testWidgets('StatsScreen renders at a narrow phone width without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myComputedStatsProvider.overrideWithValue(
            const AsyncData({'tasksCompleted': 3}),
          ),
        ],
        child: host(const StatsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready profile stats render at 360px without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    const stats = [
      ProfileStat(
        key: 'hoursTracked',
        label: 'Time tracked',
        unit: ProfileStatUnit.minutes,
        state: ProfileStatState.ready,
        value: 150,
      ),
      ProfileStat(
        key: 'focusSessions',
        label: 'Focus sessions',
        unit: ProfileStatUnit.count,
        state: ProfileStatState.ready,
        value: 4,
      ),
      ProfileStat(
        key: 'goalsAchieved',
        label: 'Goals achieved',
        unit: ProfileStatUnit.count,
        state: ProfileStatState.placeholder,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileStatsProvider.overrideWith(
            (ref, uid) => const AsyncData(stats),
          ),
        ],
        child: host(const Scaffold(body: StatsSection(uid: 'test-user'))),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('2h 30m'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });
}
