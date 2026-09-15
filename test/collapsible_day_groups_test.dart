import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_icons.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/core/widgets/collapsible_day_groups.dart';

void main() {
  Widget host({Set<String> expanded = const {}}) => MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: CollapsibleDayGroups(
        initiallyExpandedKeys: expanded,
        groups: [
          DayGroupData(
            key: '2024-01-01',
            label: 'Mon, 1 Jan',
            itemCount: 1,
            itemBuilder: (_, index) => Text('Row $index'),
          ),
        ],
      ),
    ),
  );

  testWidgets('day headers use the shared compact marker, not a serial rule', (
    tester,
  ) async {
    await tester.pumpWidget(host());

    expect(find.byIcon(AppIcons.bullet), findsOneWidget);
    final marker = tester.widget<Icon>(find.byIcon(AppIcons.bullet));
    expect(marker.size, Sizes.bulletMarker);
    expect(
      tester
          .widgetList<Container>(find.byType(Container))
          .where(
            (container) =>
                container.constraints?.maxWidth == Sizes.sectionRuleWidth &&
                container.constraints?.maxHeight == Sizes.ruleWidth,
          ),
      isEmpty,
    );
  });

  testWidgets(
    'a group transitions from collapsed through animation to expanded',
    (tester) async {
      await tester.pumpWidget(host());
      expect(find.text('Row 0'), findsNothing);

      await tester.tap(find.text('Mon, 1 Jan · 1 item'));
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 75));
      expect(find.text('Row 0'), findsOneWidget);
      final transition = tester.widget<SizeTransition>(
        find.byType(SizeTransition),
      );
      expect(transition.sizeFactor.value, greaterThan(0));
      expect(transition.sizeFactor.value, lessThan(1));

      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SizeTransition>(find.byType(SizeTransition))
            .sizeFactor
            .value,
        1,
      );

      await tester.tap(find.text('Mon, 1 Jan · 1 item'));
      await tester.pump(const Duration(milliseconds: 75));
      expect(find.text('Row 0'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Row 0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
