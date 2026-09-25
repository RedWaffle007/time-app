import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/celebrations/application/celebration_providers.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/outcomes/presentation/history_screen.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest.dart' as tz_data;

/// Regressions fixed 2026-09-25 on the My Schedule card.
void main() {
  setUpAll(tz_data.initializeTimeZones);

  final tag = find.byKey(const ValueKey('user-unavailable-tag'));
  final done = find.widgetWithText(FilledButton, 'Done');
  final skip = find.widgetWithText(OutlinedButton, 'Skip');

  testWidgets(
    'an auto-stopped alarm shows the User unavailable tag ABOVE Done/Skip',
    (tester) async {
      await _pumpSchedule(tester, [_missed()]);

      expect(tag, findsOneWidget);
      expect(find.text('User unavailable at alarm time'), findsOneWidget);
      expect(done, findsOneWidget);
      expect(skip, findsOneWidget);
      expect(
        tester.getRect(tag).bottom,
        lessThanOrEqualTo(tester.getRect(done).top),
      );
    },
  );

  testWidgets('an ordinary undecided plan shows no unavailable tag', (
    tester,
  ) async {
    await _pumpSchedule(tester, [
      _item(DateTime.now().toUtc().add(const Duration(hours: 2))),
    ]);

    expect(done, findsOneWidget);
    expect(tag, findsNothing);
  });

  testWidgets('once decided, History keeps the tag and offers no actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const HistoryScreen(), [
        _missed(outcome: const ScheduleOutcome(result: OutcomeResult.done)),
      ], _FakeScheduleRepository()),
    );
    await tester.pumpAndSettle();
    await _expandIfCollapsed(tester, 'Missed plan');

    expect(find.text('Missed plan'), findsOneWidget);
    expect(find.text('Done (Late)'), findsOneWidget);
    expect(tag, findsOneWidget);
    expect(done, findsNothing);
    expect(skip, findsNothing);
  });

  testWidgets('Done shows no Log Time pop-up', (tester) async {
    final repository = _FakeScheduleRepository();
    await _pumpSchedule(tester, [_missed()], repository: repository);

    await tester.tap(done);
    await tester.pumpAndSettle();

    expect(repository.markDoneCalls, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Log this to time tracking?'), findsNothing);
  });

  testWidgets('Done starts the celebration on save, not on the echo', (
    tester,
  ) async {
    final repository = _FakeScheduleRepository(result: Completer<bool>());
    await _pumpSchedule(tester, [_missed()], repository: repository);
    final container = ProviderScope.containerOf(tester.element(done));

    await tester.tap(done);
    await tester.pump();
    expect(
      container.read(committedCelebrationProvider),
      isNull,
      reason: 'never celebrate before the Done is committed',
    );

    repository.result!.complete(true);
    await tester.pump();
    final event = container.read(committedCelebrationProvider);
    expect(event?.itemId, 'missed');
    expect(event?.id, 'me_missed', reason: 'same id as the durable event');
    expect(event?.participantUids, ['me']);
  });

  testWidgets('a Done that lost the race does not celebrate', (tester) async {
    final repository = _FakeScheduleRepository(
      result: Completer<bool>()..complete(false),
    );
    await _pumpSchedule(tester, [_missed()], repository: repository);
    final container = ProviderScope.containerOf(tester.element(done));

    await tester.tap(done);
    await tester.pumpAndSettle();

    expect(container.read(committedCelebrationProvider), isNull);
  });
}

Future<void> _pumpSchedule(
  WidgetTester tester,
  List<ScheduleItem> items, {
  _FakeScheduleRepository? repository,
}) async {
  await tester.pumpWidget(
    _host(
      const OutcomeScreen(),
      items,
      repository ?? _FakeScheduleRepository(),
    ),
  );
  await tester.pumpAndSettle();
  await _expandIfCollapsed(tester, items.single.title);
}

Future<void> _expandIfCollapsed(WidgetTester tester, String title) async {
  if (find.text(title).evaluate().isNotEmpty) return;
  await tester.tap(find.textContaining('· 1 item').last);
  await tester.pumpAndSettle();
}

Widget _host(
  Widget screen,
  List<ScheduleItem> items,
  _FakeScheduleRepository repository,
) => ProviderScope(
  overrides: [
    myItemsAsTargetProvider.overrideWithValue(AsyncData(items)),
    profileByUidProvider.overrideWith((ref, uid) => Stream.value(null)),
    scheduleRepositoryProvider.overrideWithValue(repository),
    notificationEventNotifierProvider.overrideWithValue(_SilentNotifier()),
  ],
  child: MaterialApp(theme: AppTheme.light, home: screen),
);

/// An alarm that rang three minutes ago and auto-stopped unanswered.
ScheduleItem _missed({ScheduleOutcome? outcome}) {
  final instant = DateTime.now().toUtc().subtract(const Duration(minutes: 3));
  return _item(
    instant,
    id: 'missed',
    title: 'Missed plan',
    outcome: outcome,
    alarm: ScheduleAlarmTimeline(
      rangAt: instant,
      unavailableAt: instant.add(const Duration(minutes: 1)),
    ),
  );
}

ScheduleItem _item(
  DateTime instant, {
  String id = 'plain',
  String title = 'Plain plan',
  ScheduleOutcome? outcome,
  ScheduleAlarmTimeline? alarm,
}) => ScheduleItem(
  id: id,
  targetUid: 'me',
  createdByUid: 'me',
  groupId: '',
  title: title,
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: instant,
  status: ScheduleItemStatus.approved,
  outcome: outcome,
  alarm: alarm,
);

class _FakeScheduleRepository implements ScheduleRepository {
  _FakeScheduleRepository({this.result});

  final Completer<bool>? result;
  var markDoneCalls = 0;

  @override
  Future<bool> markDone(
    String targetUid,
    String itemId, {
    required String plannerUid,
  }) {
    markDoneCalls++;
    return result?.future ?? Future.value(true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SilentNotifier implements NotificationEventNotifier {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
