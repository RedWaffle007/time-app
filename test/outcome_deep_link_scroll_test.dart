import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  testWidgets('My Schedule identifies external and self planners', (
    tester,
  ) async {
    tz_data.initializeTimeZones();
    final utcNow = DateTime.now().toUtc();
    final todayAtNoon = DateTime.utc(utcNow.year, utcNow.month, utcNow.day, 12);
    final items = [
      _item(
        id: 'from-friend',
        title: 'Friend plan',
        instant: todayAtNoon,
        createdByUid: 'planner',
      ),
      _item(
        id: 'self-plan',
        title: 'Self plan',
        instant: todayAtNoon.add(const Duration(minutes: 30)),
      ),
    ];
    const planner = UserProfile(
      uid: 'planner',
      name: 'Amina',
      homeTimezone: 'Asia/Kolkata',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myItemsAsTargetProvider.overrideWithValue(AsyncData(items)),
          profileByUidProvider.overrideWith(
            (ref, uid) => Stream.value(uid == planner.uid ? planner : null),
          ),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const OutcomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Planned by Amina'), findsOneWidget);
    expect(find.text('Planned by you'), findsOneWidget);
    final selfCardTitle = find.descendant(
      of: find.byType(Card),
      matching: find.text('Self plan'),
    );
    final friendCardTitle = find.descendant(
      of: find.byType(Card),
      matching: find.text('Friend plan'),
    );
    expect(
      tester.getTopLeft(selfCardTitle).dy,
      lessThan(tester.getTopLeft(friendCardTitle).dy),
      reason: 'the 12:30 card must appear above the noon card',
    );
  });

  testWidgets(
    'a far deep-linked schedule item is built, revealed and highlighted',
    (tester) async {
      tz_data.initializeTimeZones();
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
  String createdByUid = 'user',
}) => ScheduleItem(
  id: id,
  targetUid: 'user',
  createdByUid: createdByUid,
  groupId: 'group',
  title: title,
  localWallTime: '09:00',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: instant,
  status: ScheduleItemStatus.approved,
);
