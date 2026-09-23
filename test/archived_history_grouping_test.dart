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
    'a two-month archive is month-grouped and an item can still be restored',
    (tester) async {
      tz_data.initializeTimeZones();
      final repository = _RecordingArchiveRepository();
      final items = [
        for (final date in [
          DateTime.utc(2026, 2, 1),
          DateTime.utc(2026, 1, 12),
        ])
          ScheduleItem(
            id: 'item-${date.month}',
            targetUid: 'me',
            createdByUid: 'me',
            groupId: '',
            title: 'Archived item ${date.month}',
            localWallTime: '',
            timezone: 'Etc/UTC',
            scheduledInstantUtc: date.add(const Duration(hours: 9)),
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

      expect(find.text('February 2026 · 1 item'), findsOneWidget);
      expect(find.text('January 2026 · 1 item'), findsOneWidget);
      expect(find.text('Archived item 2'), findsNothing);

      await tester.tap(find.text('February 2026 · 1 item'));
      await tester.pumpAndSettle();
      final firstDayHeader = find.textContaining('Feb 1, 2026 · 1 item');
      expect(firstDayHeader, findsOneWidget);
      await tester.tap(firstDayHeader);
      await tester.pumpAndSettle();

      expect(find.text('Archived item 2'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Unarchive'));
      await tester.pump();
      expect(repository.unarchived, [('me', 'item-2')]);
    },
  );
}
