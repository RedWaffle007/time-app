import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest.dart' as tz;

void main() {
  testWidgets(
    'a far deep-linked schedule item is built, revealed and highlighted',
    (tester) async {
      tz.initializeTimeZones();
      final now = DateTime.now().toUtc();
      const targetId = 'far-target';
      const targetTitle = 'Deep linked target';
      final items = [
        for (var index = 0; index < 70; index++)
          _item(
            id: index == 58 ? targetId : 'item-$index',
            title: index == 58 ? targetTitle : 'Item $index',
            instant: now.add(Duration(days: index + 1)),
          ),
      ];
      String? highlight;
      var token = 0;
      late StateSetter setHostState;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            myItemsAsTargetProvider.overrideWithValue(AsyncData(items)),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: StatefulBuilder(
              builder: (context, setState) {
                setHostState = setState;
                return OutcomeScreen(
                  highlightItemId: highlight,
                  highlightToken: token,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Only the initially-expanded date is built; the target is deliberately
      // far enough down the lazy history to prove the fallback path is needed.
      expect(find.text(targetTitle), findsNothing);

      setHostState(() {
        highlight = targetId;
        token++;
      });
      await tester.pump();
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.text(targetTitle).evaluate().isNotEmpty) break;
      }

      expect(find.text(targetTitle), findsOneWidget);
      final card = tester.widget<Card>(
        find.ancestor(of: find.text(targetTitle), matching: find.byType(Card)),
      );
      final shape = card.shape! as RoundedRectangleBorder;
      expect(shape.side.color, AppTheme.light.colorScheme.primary);
      expect(shape.side.width, Sizes.ruleWidth);

      final targetRect = tester.getRect(find.text(targetTitle));
      final view = tester.getRect(find.byType(Scaffold));
      expect(targetRect.top, greaterThanOrEqualTo(0));
      expect(targetRect.bottom, lessThanOrEqualTo(view.bottom));
      expect(tester.takeException(), isNull);
    },
  );
}

ScheduleItem _item({
  required String id,
  required String title,
  required DateTime instant,
}) => ScheduleItem(
  id: id,
  targetUid: 'user',
  createdByUid: 'user',
  groupId: 'group',
  title: title,
  localWallTime: '09:00',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: instant,
  status: ScheduleItemStatus.approved,
);
