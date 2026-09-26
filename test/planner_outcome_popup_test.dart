import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/applock/application/app_lock_controller.dart';
import 'package:time_app/features/applock/application/app_lock_providers.dart';
import 'package:time_app/features/applock/data/app_lock_store.dart';
import 'package:time_app/features/applock/data/device_auth.dart';
import 'package:time_app/features/applock/data/secure_window.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/celebrations/application/celebration_providers.dart';
import 'package:time_app/features/celebrations/data/completion_celebration_repository.dart';
import 'package:time_app/features/celebrations/domain/completion_celebration.dart';
import 'package:time_app/features/celebrations/presentation/completion_celebration_host.dart';
import 'package:time_app/features/celebrations/presentation/completion_confetti.dart';
import 'package:time_app/features/celebrations/presentation/outcome_announcement.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// Item 18 (2026-09-26): the planner's in-app pop-up for Done (with confetti)
/// and Skipped (without), driven by the durable celebration record.

CompletionCelebration _event(
  String itemId, {
  CelebrationResult result = CelebrationResult.done,
}) => CompletionCelebration(
  id: result == CelebrationResult.done
      ? CompletionCelebration.eventId('TARGET', itemId)
      : CompletionCelebration.skippedEventId('TARGET', itemId),
  itemId: itemId,
  targetUid: 'TARGET',
  plannerUid: 'PLANNER',
  participantUids: result == CelebrationResult.done
      ? const ['TARGET', 'PLANNER']
      : const ['PLANNER'],
  seenByUids: const [],
  result: result,
);

ScheduleItem _item(String id, String title) => ScheduleItem(
  id: id,
  targetUid: 'TARGET',
  createdByUid: 'PLANNER',
  groupId: '',
  title: title,
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: DateTime.utc(2030),
  status: ScheduleItemStatus.approved,
);

class _Store implements CompletionCelebrationStore {
  _Store(this.stream);
  final Stream<List<CompletionCelebration>> stream;
  final acknowledged = <String>[];

  @override
  Stream<List<CompletionCelebration>> watchUnseen(String uid) => stream;

  @override
  Future<void> acknowledge(CompletionCelebration event, String uid) async {
    acknowledged.add(event.id);
  }
}

class _NoopLockStore implements AppLockStore {
  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<void> setEnabled(bool value) async {}
}

class _NoopDeviceAuth implements DeviceAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopSecureWindow implements SecureWindow {
  @override
  Future<void> setSecure(bool enabled) async {}
}

Future<_Store> _pump(
  WidgetTester tester,
  List<CompletionCelebration> events, {
  String uid = 'PLANNER',
  String? targetName = 'Test Target',
  List<ScheduleItem>? items,
  ThemeData? theme,
}) async {
  final store = _Store(Stream.value(events));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUidProvider.overrideWithValue(uid),
        completionCelebrationRepositoryProvider.overrideWithValue(store),
        profileByUidProvider.overrideWith(
          (ref, id) => Stream.value(
            targetName == null
                ? null
                : UserProfile(uid: id, name: targetName, homeTimezone: 'UTC'),
          ),
        ),
        allItemsAsPlannerProvider.overrideWith(
          (ref) =>
              Stream.value(items ?? [_item('a', 'Gym'), _item('b', 'Read')]),
        ),
        appLockControllerProvider.overrideWithValue(
          AppLockController(
            store: _NoopLockStore(),
            auth: _NoopDeviceAuth(),
            secureWindow: _NoopSecureWindow(),
            initiallyEnabled: false,
          ),
        ),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.light,
        home: const CompletionCelebrationHost(
          child: Scaffold(body: Text('APP')),
        ),
      ),
    ),
  );
  // Let the event, profile and item streams all deliver (without running the
  // 1.4 s confetti to completion, which pumpAndSettle would).
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  return store;
}

Finder get _card => find.byKey(OutcomeAnnouncementCard.cardKey);
Finder get _confetti => find.byType(CompletionConfetti);

void main() {
  group('copy', () {
    test('Done is celebratory and names the person and task', () {
      final copy = outcomeAnnouncementCopy(
        result: CelebrationResult.done,
        targetName: 'Test Target',
        taskTitle: 'Gym',
      );
      expect(copy.heading, 'Your planning skills are amazing!');
      expect(copy.body, 'Test Target completed task: Gym');
    });

    test('Skipped keeps the same body shape with a plain heading', () {
      final copy = outcomeAnnouncementCopy(
        result: CelebrationResult.skipped,
        targetName: 'Test Target',
        taskTitle: 'Gym',
      );
      expect(copy.heading, 'Plan skipped');
      expect(copy.body, 'Test Target skipped task: Gym');
      expect(copy.heading, isNot(contains('amazing')));
    });

    test('missing name or title never renders blank', () {
      final copy = outcomeAnnouncementCopy(
        result: CelebrationResult.done,
        targetName: '  ',
        taskTitle: null,
      );
      expect(copy.body, 'Someone completed task: your plan');
    });
  });

  group('audience', () {
    test('only the planner of someone else\'s item sees the pop-up', () {
      final done = _event('a');
      expect(showsPlannerAnnouncement(done, 'PLANNER'), isTrue);
      expect(showsPlannerAnnouncement(done, 'TARGET'), isFalse);
      expect(showsPlannerAnnouncement(done, 'OUTSIDER'), isFalse);
      expect(showsPlannerAnnouncement(done, null), isFalse);
      final self = CompletionCelebration(
        id: 'self',
        itemId: 'a',
        targetUid: 'PLANNER',
        plannerUid: 'PLANNER',
        participantUids: const ['PLANNER'],
        seenByUids: const [],
      );
      expect(showsPlannerAnnouncement(self, 'PLANNER'), isFalse);
    });

    test('Skip records use their own id, beside the Done id', () {
      expect(
        CompletionCelebration.skippedEventId('TARGET', 'a'),
        isNot(CompletionCelebration.eventId('TARGET', 'a')),
      );
      expect(_event('a').isDone, isTrue);
      expect(_event('a', result: CelebrationResult.skipped).isDone, isFalse);
    });
  });

  group('host', () {
    testWidgets('planner + Done: confetti AND pop-up; acknowledged on tap', (
      tester,
    ) async {
      final store = await _pump(tester, [_event('a')]);

      expect(_confetti, findsOneWidget);
      expect(_card, findsOneWidget);
      expect(find.text('Your planning skills are amazing!'), findsOneWidget);
      expect(find.text('Test Target completed task: Gym'), findsOneWidget);

      // Confetti ends on its own; the pop-up waits for the person.
      await tester.pump(completionCelebrationDuration);
      await tester.pump();
      expect(_confetti, findsNothing);
      expect(_card, findsOneWidget);
      expect(store.acknowledged, isEmpty);

      await tester.tap(find.text('Nice'));
      await tester.pumpAndSettle();
      expect(_card, findsNothing);
      expect(store.acknowledged, [_event('a').id]);
    });

    testWidgets('planner + Skipped: pop-up without confetti', (tester) async {
      final skip = _event('a', result: CelebrationResult.skipped);
      final store = await _pump(tester, [skip]);

      expect(_confetti, findsNothing);
      expect(find.text('Plan skipped'), findsOneWidget);
      expect(find.text('Test Target skipped task: Gym'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(_card, findsNothing);
      expect(_confetti, findsNothing);
      expect(store.acknowledged, [skip.id]);
    });

    testWidgets('target + Done: confetti only, as before', (tester) async {
      final store = await _pump(tester, [_event('a')], uid: 'TARGET');
      expect(_confetti, findsOneWidget);
      expect(_card, findsNothing);
      await tester.pump(completionCelebrationDuration);
      await tester.pumpAndSettle();
      expect(store.acknowledged, [_event('a').id]);
    });

    testWidgets('tapping outside the pop-up dismisses it', (tester) async {
      final skip = _event('a', result: CelebrationResult.skipped);
      final store = await _pump(tester, [skip]);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(_card, findsNothing);
      expect(store.acknowledged, [skip.id]);
    });

    testWidgets('queued outcomes show one at a time, in order', (tester) async {
      final done = _event('a');
      final skip = _event('b', result: CelebrationResult.skipped);
      final store = await _pump(tester, [done, skip]);

      expect(find.text('Test Target completed task: Gym'), findsOneWidget);
      expect(find.text('Test Target skipped task: Read'), findsNothing);

      await tester.pump(completionCelebrationDuration);
      await tester.tap(find.text('Nice'));
      await tester.pumpAndSettle();
      expect(find.text('Test Target skipped task: Read'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(store.acknowledged, [done.id, skip.id]);
      expect(_card, findsNothing);
    });

    testWidgets('a missing profile and item still reads sensibly', (
      tester,
    ) async {
      await _pump(tester, [_event('zzz')], targetName: null, items: const []);
      expect(find.text('Someone completed task: your plan'), findsOneWidget);
    });

    testWidgets('renders in dark mode', (tester) async {
      await _pump(tester, [
        _event('a', result: CelebrationResult.skipped),
      ], theme: AppTheme.dark);
      expect(_card, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test('the committed (local) Done event stays a Done', () {
    final local = CompletionCelebration.committed(
      targetUid: 'TARGET',
      itemId: 'a',
      plannerUid: 'PLANNER',
    );
    expect(local.isDone, isTrue);
    expect(local.id, CompletionCelebration.eventId('TARGET', 'a'));
  });
}
