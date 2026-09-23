import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/archive/application/archive_providers.dart';
import 'package:time_app/features/archive/data/archive_repository.dart';
import 'package:time_app/features/archive/presentation/archived_screen.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest.dart' as tz_data;

class _RecordingArchiveRepository implements ArchiveRepository {
  final unarchived = <(String, String)>[];

  @override
  Future<void> unarchive(String uid, String itemId) async {
    unarchived.add((uid, itemId));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'a long archive stays grouped and an item can still be restored',
    (tester) async {
      tz_data.initializeTimeZones();
      final repository = _RecordingArchiveRepository();
      final items = [
        for (var day = 12; day >= 1; day--)
          ScheduleItem(
            id: 'item-$day',
            targetUid: 'me',
            createdByUid: 'me',
            groupId: '',
            title: 'Archived item $day',
            localWallTime: '',
            timezone: 'Etc/UTC',
            scheduledInstantUtc: DateTime.utc(2026, 1, day, 9),
            status: ScheduleItemStatus.approved,
            outcome: const ScheduleOutcome(result: OutcomeResult.done),
          ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            archivedItemsProvider.overrideWithValue(AsyncData(items)),
            currentUidProvider.overrideWithValue('me'),
            archiveRepositoryProvider.overrideWithValue(repository),
            profileByUidProvider.overrideWith((ref, uid) => Stream.value(null)),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const ArchivedScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('January 2026 · 12 items'), findsOneWidget);
      expect(find.text('Archived item 12'), findsNothing);

      await tester.tap(find.text('January 2026 · 12 items'));
      await tester.pumpAndSettle();
      final firstDayHeader = find.textContaining('Jan 12, 2026 · 1 item');
      expect(firstDayHeader, findsOneWidget);
      await tester.tap(firstDayHeader);
      await tester.pumpAndSettle();

      expect(find.text('Archived item 12'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Unarchive'));
      await tester.pump();
      expect(repository.unarchived, [('me', 'item-12')]);
    },
  );
}
