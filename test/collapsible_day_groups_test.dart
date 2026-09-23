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
            date: DateTime(2024, 1, 1),
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

  testWidgets(
    'collapsed history does not allocate one animation controller per day',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: CollapsibleDayGroups(
              groups: [
                for (var index = 0; index < 40; index++)
                  DayGroupData(
                    key: '2024-02-${(index + 1).toString().padLeft(2, '0')}',
                    date: DateTime(2024, 2, index + 1),
                    label: 'Day $index',
                    itemCount: 1,
                    itemBuilder: (_, row) => Text('Row $index:$row'),
                  ),
              ],
            ),
          ),
        ),
      );

      expect(CollapsibleDayGroups.debugAnimationControllerCount, 0);
      await tester.tap(find.text('February 2024 · 29 items'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Day 0 · 1 item'));
      await tester.pump(const Duration(milliseconds: 75));
      expect(CollapsibleDayGroups.debugAnimationControllerCount, 1);

      await tester.tap(find.text('Day 0 · 1 item'));
      await tester.pumpAndSettle();
      expect(CollapsibleDayGroups.debugAnimationControllerCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long histories collapse into localized month-year buckets', (
    tester,
  ) async {
    final groups = [
      for (var month = 1; month <= 2; month++)
        for (var day = 1; day <= 6; day++)
          DayGroupData(
            key:
                '2024-${month.toString().padLeft(2, '0')}-'
                '${day.toString().padLeft(2, '0')}',
            date: DateTime(2024, month, day),
            label: 'Month $month day $day',
            itemCount: 1,
            itemBuilder: (_, _) => Text('Row $month:$day'),
          ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: CollapsibleDayGroups(groups: groups)),
      ),
    );

    expect(find.text('January 2024 · 6 items'), findsOneWidget);
    expect(find.text('February 2024 · 6 items'), findsOneWidget);
    expect(find.text('Month 1 day 1 · 1 item'), findsNothing);

    await tester.tap(find.text('January 2024 · 6 items'));
    await tester.pumpAndSettle();
    expect(find.text('Month 1 day 1 · 1 item'), findsOneWidget);
    expect(find.text('Month 1 day 6 · 1 item'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Month 1 day 1 · 1 item')).dy,
      lessThan(tester.getTopLeft(find.text('Month 1 day 6 · 1 item')).dy),
      reason: 'month grouping must preserve the caller\'s day order',
    );
  });

  testWidgets('a forced day opens both its month and its own rows', (
    tester,
  ) async {
    final groups = [
      for (var index = 0; index < 12; index++)
        DayGroupData(
          key: '2024-02-${(index + 1).toString().padLeft(2, '0')}',
          date: DateTime(2024, 2, index + 1),
          label: 'Day ${index + 1}',
          itemCount: 1,
          itemBuilder: (_, _) => Text('Row ${index + 1}'),
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: CollapsibleDayGroups(
            groups: groups,
            forceExpandKey: '2024-02-04',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('February 2024 · 12 items'), findsOneWidget);
    expect(find.text('Day 4 · 1 item'), findsOneWidget);
    expect(find.text('Row 4'), findsOneWidget);
    expect(find.text('Row 3'), findsNothing);
  });

  testWidgets('group headers expose button, header, and expanded semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(host());

      final header = find.bySemanticsLabel('Mon, 1 Jan · 1 item');
      expect(header, findsOneWidget);
      expect(
        tester.getSemantics(header),
        matchesSemantics(
          label: 'Mon, 1 Jan · 1 item',
          hint: 'Expand group',
          isButton: true,
          isHeader: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
        ),
      );

      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.bySemanticsLabel('Mon, 1 Jan · 1 item')),
        matchesSemantics(
          label: 'Mon, 1 Jan · 1 item',
          hint: 'Collapse group',
          isButton: true,
          isHeader: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
        ),
      );
    } finally {
      semantics.dispose();
    }
  });
}
