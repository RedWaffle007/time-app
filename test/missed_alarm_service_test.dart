import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/widgets/app_overlay_scope.dart';
import 'package:time_app/features/applock/application/app_lock_controller.dart';
import 'package:time_app/features/applock/application/app_lock_providers.dart';
import 'package:time_app/features/applock/data/app_lock_store.dart';
import 'package:time_app/features/applock/data/device_auth.dart';
import 'package:time_app/features/applock/data/secure_window.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/celebrations/application/celebration_providers.dart';
import 'package:time_app/features/outcomes/application/outcome_feedback.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/reminders/application/missed_alarm_providers.dart';
import 'package:time_app/features/reminders/application/missed_alarm_service.dart';
import 'package:time_app/features/reminders/application/reminder_providers.dart';
import 'package:time_app/features/reminders/data/alarm_sound.dart';
import 'package:time_app/features/reminders/data/alarm_lifecycle_store.dart';
import 'package:time_app/features/reminders/data/alarm_timeline_repository.dart';
import 'package:time_app/features/reminders/presentation/missed_alarm_review_host.dart';
import 'package:time_app/features/scheduling/application/item_lapse_policy.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/voice_notes/application/voice_note_cache.dart';
import 'package:time_app/features/voice_notes/application/voice_note_providers.dart';
import 'package:time_app/features/voice_notes/data/voice_player.dart';

void main() {
  _voiceFallbackTests();
  setUpAll(tzdata.initializeTimeZones);

  test('native dismissal names migrate without becoming false timeouts', () {
    Map<String, Object> event(String kind) => {
      'key': '$kind:item:1000',
      'itemId': 'item',
      'occurredAtEpoch': 1000,
      'kind': kind,
    };

    expect(
      AlarmLifecycleEvent.fromMap(event('volume_silenced'))?.kind,
      AlarmLifecycleEventKind.dismissed,
    );
    expect(
      AlarmLifecycleEvent.fromMap(event('dismissed'))?.kind,
      AlarmLifecycleEventKind.dismissed,
    );
    expect(AlarmLifecycleEvent.fromMap(event('future_kind')), isNull);

    final reviewed = AlarmLifecycleEvent.fromMap({
      ...event('timeout'),
      'reviewed': true,
      'reviewChoice': 'done',
      'reviewNotificationDelivered': true,
    });
    expect(reviewed?.reviewChoice, MissedAlarmReviewChoice.done);
    expect(reviewed?.reviewNotificationDelivered, isTrue);
  });

  test(
    'timeout records ONLY the unavailable fact — no outcome, no push — and awaits review',
    () async {
      // Regression (2026-09-25): an auto-stopped alarm used to write
      // Skipped: User unavailable, moving the task to History before the
      // person decided anything.
      final store = _MemoryLifecycleStore([_event()]);
      final outcomes = _RecordingOutcomes();
      final timeline = _RecordingTimeline();
      final notifier = _RecordingNotifier();
      final service = MissedAlarmService(
        store: store,
        outcomes: outcomes,
        timeline: timeline,
        notifier: notifier,
      );

      await service.sync([_item()], 'target');
      await _settle();

      expect(timeline.unavailable, [('target', 'item')]);
      expect(timeline.unavailableTimes, [
        DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      ]);
      expect(outcomes.skipped, isEmpty);
      expect(outcomes.done, isEmpty);
      expect(notifier.calls, isEmpty);
      expect(service.reviews.single.item.id, 'item');
      expect(store.events.single.outcomeRecorded, isTrue);
    },
  );

  test('the unavailable fact is written once, not on every sync', () async {
    final store = _MemoryLifecycleStore([_event()]);
    final timeline = _RecordingTimeline();
    final service = MissedAlarmService(
      store: store,
      outcomes: _RecordingOutcomes(),
      timeline: timeline,
      notifier: _RecordingNotifier(),
    );

    await service.sync([_item()], 'target');
    await service.sync([_item(unavailableAt: _occurred)], 'target');
    await service.sync([_item(unavailableAt: _occurred)], 'target');

    expect(timeline.unavailable, hasLength(1));
    expect(service.reviews, hasLength(1));
  });

  test(
    'the popup does not wait for the Firestore fact write (was a multi-second delay)',
    () async {
      final gate = Completer<void>();
      final timeline = _RecordingTimeline(gate: gate.future);
      final store = _MemoryLifecycleStore([_event()]);
      final service = MissedAlarmService(
        store: store,
        outcomes: _RecordingOutcomes(),
        timeline: timeline,
        notifier: _RecordingNotifier(),
      );

      await service.sync([_item()], 'target');

      expect(service.reviews, hasLength(1), reason: 'shown before the write');
      expect(store.events.single.outcomeRecorded, isFalse);

      gate.complete();
      await _settle();
      expect(store.events.single.outcomeRecorded, isTrue);
      expect(timeline.unavailable, hasLength(1));
    },
  );

  test('an in-flight fact write is not duplicated by the next sync', () async {
    final gate = Completer<void>();
    final timeline = _RecordingTimeline(gate: gate.future);
    final service = MissedAlarmService(
      store: _MemoryLifecycleStore([_event()]),
      outcomes: _RecordingOutcomes(),
      timeline: timeline,
      notifier: _RecordingNotifier(),
    );

    await service.sync([_item()], 'target');
    await service.sync([_item()], 'target');
    gate.complete();
    await _settle();

    expect(timeline.unavailable, hasLength(1));
  });

  test(
    'Done persists the fact before the outcome (so it reads Done (Late))',
    () async {
      final order = <String>[];
      final timeline = _RecordingTimeline(
        onUnavailable: () => order.add('fact'),
      );
      final outcomes = _RecordingOutcomes(onWrite: () => order.add('outcome'));
      final service = MissedAlarmService(
        store: _MemoryLifecycleStore([_event()]),
        outcomes: outcomes,
        timeline: timeline,
        notifier: _RecordingNotifier(),
      );
      await service.sync([_item()], 'target');
      order.clear(); // the background write may still be pending — irrelevant

      await service.markDone(service.reviews.single);

      expect(order, contains('fact'));
      expect(order.indexOf('fact'), lessThan(order.indexOf('outcome')));
    },
  );

  test(
    'KEEP: an unanswered popup re-appears after the app is closed and reopened',
    () async {
      // Directed to preserve 2026-09-25: clearing the app without choosing
      // Done/Skip must not lose the question.
      final store = _MemoryLifecycleStore([_event()]);
      MissedAlarmService freshProcess() => MissedAlarmService(
        store: store,
        outcomes: _RecordingOutcomes(),
        timeline: _RecordingTimeline(),
        notifier: _RecordingNotifier(),
      );

      final first = freshProcess();
      await first.sync([_item()], 'target');
      await _settle();
      expect(first.reviews, hasLength(1));

      // Process killed; a new one reads the same durable native row.
      for (var launch = 0; launch < 3; launch++) {
        final next = freshProcess();
        await next.sync([_item(unavailableAt: _occurred)], 'target');
        expect(next.reviews, hasLength(1), reason: 'launch $launch');
      }
    },
  );

  test('review is visible without waiting for any network push', () async {
    final gate = Completer<void>();
    final service = MissedAlarmService(
      store: _MemoryLifecycleStore([_event()]),
      outcomes: _RecordingOutcomes(),
      timeline: _RecordingTimeline(),
      notifier: _BlockingNotifier(gate.future),
    );

    await service.sync([_item()], 'target');

    expect(service.reviews, hasLength(1));
    gate.complete();
  });

  test('Mark as Done records Done and tells the planner once', () async {
    final store = _MemoryLifecycleStore([_event()]);
    final outcomes = _RecordingOutcomes();
    final notifier = _RecordingNotifier();
    final service = MissedAlarmService(
      store: store,
      outcomes: outcomes,
      timeline: _RecordingTimeline(),
      notifier: notifier,
    );
    await service.sync([_item()], 'target');

    final committed = await service.markDone(service.reviews.single);
    await _settle();

    expect(committed, isTrue);
    expect(outcomes.done, [('target', 'item', 'planner')]);
    expect(outcomes.legacyDone, isEmpty);
    expect(outcomes.skipped, isEmpty);
    expect(notifier.calls, [('target', 'item')]);
    expect(service.reviews, isEmpty);

    // The stream catches up with the Done: the row is finished and removed.
    await service.sync([
      _item(
        unavailableAt: _occurred,
        outcome: const ScheduleOutcome(result: OutcomeResult.done),
      ),
    ], 'target');
    expect(store.events, isEmpty);
    expect(notifier.calls, hasLength(1));
  });

  test(
    'Mark as Skipped records Skipped: User unavailable and tells the planner',
    () async {
      final store = _MemoryLifecycleStore([_event()]);
      final outcomes = _RecordingOutcomes();
      final notifier = _RecordingNotifier();
      final service = MissedAlarmService(
        store: store,
        outcomes: outcomes,
        timeline: _RecordingTimeline(),
        notifier: notifier,
      );
      await service.sync([_item()], 'target');

      await service.markSkipped(service.reviews.single);
      await _settle();

      expect(outcomes.skipped, [
        ('target', 'item', kUserUnavailableSkipReason),
      ]);
      expect(outcomes.done, isEmpty);
      expect(notifier.calls, [('target', 'item')]);
      // The in-app Skip pop-up goes to the item's planner (2026-09-26).
      expect(outcomes.skipAnnouncedTo, [_item().createdByUid]);

      await service.sync([
        _item(
          unavailableAt: _occurred,
          outcome: const ScheduleOutcome(
            result: OutcomeResult.skipped,
            skipReason: kUserUnavailableSkipReason,
          ),
        ),
      ], 'target');
      expect(store.events, isEmpty);
      expect(service.reviews, isEmpty);
    },
  );

  test('a self-planned review choice sends no push', () async {
    final store = _MemoryLifecycleStore([_event()]);
    final notifier = _RecordingNotifier();
    final service = MissedAlarmService(
      store: store,
      outcomes: _RecordingOutcomes(),
      timeline: _RecordingTimeline(),
      notifier: notifier,
    );
    await service.sync([_item(createdByUid: 'target')], 'target');

    await service.markDone(service.reviews.single);
    await _settle();

    expect(notifier.calls, isEmpty);
    expect(store.events.single.reviewNotificationDelivered, isTrue);
  });

  test(
    'a choice that lost the race reports no commit and never overwrites',
    () async {
      final store = _MemoryLifecycleStore([_event()]);
      final outcomes = _RecordingOutcomes(recorded: false);
      final notifier = _RecordingNotifier();
      final service = MissedAlarmService(
        store: store,
        outcomes: outcomes,
        timeline: _RecordingTimeline(),
        notifier: notifier,
      );
      await service.sync([_item()], 'target');

      final committed = await service.markDone(service.reviews.single);
      await _settle();

      expect(committed, isFalse);
      expect(notifier.calls, isEmpty);
    },
  );

  test(
    'a Done/Skip made on the card (or another device) closes the review',
    () async {
      final store = _MemoryLifecycleStore([_event()]);
      final outcomes = _RecordingOutcomes();
      final notifier = _RecordingNotifier();
      final service = MissedAlarmService(
        store: store,
        outcomes: outcomes,
        timeline: _RecordingTimeline(),
        notifier: notifier,
      );
      await service.sync([_item()], 'target');
      expect(service.reviews, hasLength(1));

      await service.sync([
        _item(
          unavailableAt: _occurred,
          outcome: const ScheduleOutcome(result: OutcomeResult.done),
        ),
      ], 'target');
      await _settle();

      expect(service.reviews, isEmpty);
      expect(store.events, isEmpty);
      expect(outcomes.done, isEmpty, reason: 'never rewrite a card outcome');
      expect(notifier.calls, isEmpty, reason: 'the card already notified');
    },
  );

  test('manual outcome that beat the timeout still gets the fact', () async {
    final store = _MemoryLifecycleStore([_event()]);
    final outcomes = _RecordingOutcomes();
    final timeline = _RecordingTimeline();
    final service = MissedAlarmService(
      store: store,
      outcomes: outcomes,
      timeline: timeline,
      notifier: _RecordingNotifier(),
    );

    await service.sync([
      _item(
        outcome: ScheduleOutcome(
          result: OutcomeResult.done,
          completedAt: DateTime.utc(2026, 9, 23, 9),
        ),
      ),
    ], 'target');

    expect(outcomes.skipped, isEmpty);
    expect(outcomes.done, isEmpty);
    expect(timeline.unavailable, [('target', 'item')]);
    expect(store.events, isEmpty);
    expect(service.reviews, isEmpty);
  });

  test(
    'the end-of-day lapse settles an undecided miss without rewriting it',
    () async {
      final store = _MemoryLifecycleStore([_event()]);
      final outcomes = _RecordingOutcomes();
      final service = MissedAlarmService(
        store: store,
        outcomes: outcomes,
        timeline: _RecordingTimeline(),
        notifier: _RecordingNotifier(),
      );
      await service.sync([_item()], 'target');

      await service.sync([
        _item(
          unavailableAt: _occurred,
          outcome: const ScheduleOutcome(
            result: OutcomeResult.skipped,
            skipReason: kLapsedSkipReason,
          ),
        ),
      ], 'target');

      expect(outcomes.skipped, isEmpty);
      expect(outcomes.done, isEmpty);
      expect(store.events, isEmpty);
      expect(service.reviews, isEmpty);
    },
  );

  test(
    'a persisted choice whose write never landed is finished on next sync',
    () async {
      // Process death between markReviewChoice and the Firestore write.
      final store = _MemoryLifecycleStore([
        _event(
          outcomeRecorded: true,
          reviewChoice: MissedAlarmReviewChoice.skipped,
        ),
      ]);
      final outcomes = _RecordingOutcomes();
      final notifier = _RecordingNotifier();
      final service = MissedAlarmService(
        store: store,
        outcomes: outcomes,
        timeline: _RecordingTimeline(),
        notifier: notifier,
      );

      await service.sync([_item(unavailableAt: _occurred)], 'target');
      await _settle();

      expect(service.reviews, isEmpty, reason: 'no second popup');
      expect(outcomes.skipped, [
        ('target', 'item', kUserUnavailableSkipReason),
      ]);
      expect(notifier.calls, [('target', 'item')]);
    },
  );

  test('a failed planner push stays durable and retries', () async {
    final store = _MemoryLifecycleStore([_event()]);
    final notifier = _RecordingNotifier(results: [false, true]);
    final service = MissedAlarmService(
      store: store,
      outcomes: _RecordingOutcomes(),
      timeline: _RecordingTimeline(),
      notifier: notifier,
    );
    await service.sync([_item()], 'target');
    await service.markSkipped(service.reviews.single);
    await _settle();
    expect(store.events.single.reviewNotificationDelivered, isFalse);

    final skipped = _item(
      unavailableAt: _occurred,
      outcome: const ScheduleOutcome(
        result: OutcomeResult.skipped,
        skipReason: kUserUnavailableSkipReason,
      ),
    );
    await service.sync([skipped], 'target');
    await _settle();

    expect(notifier.calls, hasLength(2));
    expect(store.events, isEmpty);
  });

  group('legacy rows from builds that auto-skipped at timeout', () {
    AlarmLifecycleEvent legacyEvent({bool notificationDelivered = true}) =>
        _event(
          outcomeRecorded: true,
          notificationDelivered: notificationDelivered,
        );
    ScheduleItem legacyItem({ScheduleAlarmTimeline? alarm}) => _item(
      unavailableAt: alarm?.unavailableAt,
      outcome: const ScheduleOutcome(
        result: OutcomeResult.skipped,
        skipReason: kUserUnavailableSkipReason,
      ),
    );

    test('are still offered for review and backfill the fact', () async {
      final timeline = _RecordingTimeline();
      final service = MissedAlarmService(
        store: _MemoryLifecycleStore([legacyEvent()]),
        outcomes: _RecordingOutcomes(),
        timeline: timeline,
        notifier: _RecordingNotifier(),
      );

      await service.sync([legacyItem()], 'target');

      expect(timeline.unavailable, [('target', 'item')]);
      expect(service.reviews, hasLength(1));
    });

    test('deliver their owed automatic-skip push', () async {
      final store = _MemoryLifecycleStore([
        legacyEvent(notificationDelivered: false),
      ]);
      final notifier = _RecordingNotifier();
      final service = MissedAlarmService(
        store: store,
        outcomes: _RecordingOutcomes(),
        timeline: _RecordingTimeline(),
        notifier: notifier,
      );

      await service.sync([
        legacyItem(alarm: ScheduleAlarmTimeline(unavailableAt: _occurred)),
      ], 'target');
      await _settle();

      expect(notifier.calls, [('target', 'item')]);
      expect(store.events.single.notificationDelivered, isTrue);
    });

    test('Done corrects exactly the automatic skip', () async {
      final outcomes = _RecordingOutcomes();
      final service = MissedAlarmService(
        store: _MemoryLifecycleStore([legacyEvent()]),
        outcomes: outcomes,
        timeline: _RecordingTimeline(),
        notifier: _RecordingNotifier(),
      );
      await service.sync([
        legacyItem(alarm: ScheduleAlarmTimeline(unavailableAt: _occurred)),
      ], 'target');

      final committed = await service.markDone(service.reviews.single);

      expect(committed, isTrue);
      expect(outcomes.legacyDone, [('target', 'item', 'planner')]);
      expect(outcomes.done, isEmpty);
    });
  });

  test('volume silence is reconciled as dismissal without skipping', () async {
    final store = _MemoryLifecycleStore([
      _event(kind: AlarmLifecycleEventKind.dismissed),
    ]);
    final outcomes = _RecordingOutcomes();
    final timeline = _RecordingTimeline();
    final service = MissedAlarmService(
      store: store,
      outcomes: outcomes,
      timeline: timeline,
      notifier: _RecordingNotifier(),
    );

    await service.sync([_item()], 'target');

    expect(timeline.dismissed, [('target', 'item')]);
    expect(timeline.unavailable, isEmpty);
    expect(outcomes.skipped, isEmpty);
    expect(store.events, isEmpty);
    expect(service.reviews, isEmpty);
  });

  group('missedPopupMessage (R3)', () {
    test('a Default Alarm leads with the alarm sentence', () {
      expect(
        missedPopupMessage(_item(), plannerName: '{planner}'),
        '{planner} planned Morning walk for you. '
        'It rang 3 times with no response.',
      );
      expect(
        missedPopupMessage(_item()),
        'Someone planned Morning walk for you. '
        'It rang 3 times with no response.',
      );
    });

    test('a self-plan needs no name', () {
      expect(
        missedPopupMessage(_item(createdByUid: 'target'), plannerName: 'x'),
        'You planned Morning walk. It rang 3 times with no response.',
      );
    });

    test('a voice note names the planner, or Someone, never "Your friend"', () {
      expect(
        missedPopupMessage(
          _item(voiceNote: _voiceMeta),
          plannerName: '{planner}',
        ),
        '{planner} sent you a voice note. Listen now?',
      );
      expect(
        missedPopupMessage(_item(voiceNote: _voiceMeta), plannerName: ' '),
        'Someone sent you a voice note. Listen now?',
      );
    });
  });

  // R6 (2026-10-02): "Send note" sits with the missed popup's answers.
  group('Missed pop-up: two card decks (2026-10-05)', () {
    late _RecordingOutcomes outcomes;
    late _RecordingTimeline timeline;
    late _RecordingNotifier notifier;
    late _ReplyRepo replies;

    ScheduleItem rung(
      String id, {
      bool voice = false,
      String createdBy = 'planner',
      String title = 'Morning walk',
    }) => ScheduleItem(
      id: id,
      voiceNote: voice ? _voiceMeta : null,
      targetUid: 'target',
      createdByUid: createdBy,
      alarm: ScheduleAlarmTimeline(rangAt: _occurred, ring: 1),
      groupId: '',
      title: title,
      localWallTime: '',
      timezone: 'Etc/UTC',
      scheduledInstantUtc: DateTime.utc(2026, 9, 23, 8),
      status: ScheduleItemStatus.approved,
    );

    Future<ProviderContainer> open(
      WidgetTester tester,
      List<ScheduleItem> items, {
      List<AlarmLifecycleEvent> events = const [],
      VoiceNoteCache? cache,
      Set<String> ringing = const {},
      bool locked = false,
      // Where the real app puts it: in MaterialApp.builder, above the
      // router's navigator (device report 2026-10-05).
      bool aboveRouter = false,
    }) async {
      outcomes = _RecordingOutcomes();
      timeline = _RecordingTimeline();
      notifier = _RecordingNotifier();
      replies = _ReplyRepo();
      final service = MissedAlarmService(
        store: _MemoryLifecycleStore(events),
        outcomes: outcomes,
        timeline: timeline,
        notifier: notifier,
      );
      final lock = AppLockController(
        store: _NoopLockStore(),
        auth: _NoopDeviceAuth(),
        secureWindow: _NoopSecureWindow(),
        initiallyEnabled: locked,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            missedAlarmServiceProvider.overrideWithValue(service),
            appLockControllerProvider.overrideWithValue(lock),
            currentUidProvider.overrideWithValue('target'),
            allItemsAsTargetProvider.overrideWith(
              (ref) => Stream.value(items),
            ),
            alarmSoundProvider.overrideWithValue(_RingingSound(ringing)),
            scheduleRepositoryProvider.overrideWithValue(replies),
            notificationEventNotifierProvider.overrideWithValue(notifier),
            voiceNoteCacheProvider.overrideWithValue(cache ?? _Cache()),
            voicePlayerProvider.overrideWithValue(_Player()),
            profileByUidProvider.overrideWith(
              (ref, uid) => Stream.value(
                const UserProfile(
                  uid: 'planner',
                  name: '{planner}',
                  homeTimezone: 'Etc/UTC',
                ),
              ),
            ),
          ],
          child: aboveRouter
              ? MaterialApp(
                  theme: AppTheme.light,
                  builder: (context, child) => AppOverlayScope(
                    child: MissedAlarmReviewHost(enabled: true, child: child!),
                  ),
                  home: const Scaffold(body: Text('Schedule')),
                )
              : MaterialApp(
                  theme: AppTheme.light,
                  home: const MissedAlarmReviewHost(
                    enabled: true,
                    child: Scaffold(body: Text('Schedule')),
                  ),
                ),
        ),
      );
      await service.sync(items, 'target');
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(tester.element(find.text('Schedule')));
    }

    final popup = find.byKey(const ValueKey('missed-popup'));

    testWidgets('voice notes come first, one card at a time, with who, '
        'when and the three actions', (tester) async {
      await open(tester, [
        rung('alarm-1'),
        rung('voice-1', voice: true),
        rung('voice-2', voice: true),
      ]);
      expect(find.text('Missed voice notes'), findsOneWidget);
      expect(find.text('1 of 2'), findsOneWidget);
      expect(find.text('{planner} sent you a voice alarm'), findsOneWidget);
      expect(find.textContaining('Planned for'), findsOneWidget);
      expect(find.text('Already heard'), findsOneWidget);
      expect(find.text('Send note'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      // The default alarm waits for its own deck.
      expect(find.text('Missed alarms'), findsNothing);
      expect(find.byKey(const ValueKey('missed-done-alarm-1')), findsNothing);
    });

    testWidgets('swiping moves between cards, both ways', (tester) async {
      await open(tester, [
        rung('voice-1', voice: true),
        rung('voice-2', voice: true),
      ]);
      await tester.drag(
        find.byKey(const ValueKey('missed-pages')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 of 2'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('missed-pages')),
        const Offset(400, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 of 2'), findsOneWidget);
    });

    testWidgets('Play keeps the card up while the note plays, then shows '
        'Played with Send note still there, and closes to confetti', (
      tester,
    ) async {
      final container = await open(tester, [rung('voice-1', voice: true)]);
      await tester.tap(find.byKey(const ValueKey('missed-play-voice-1')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Playing…'), findsOneWidget);
      expect(popup, findsOneWidget);
      expect(outcomes.done, isEmpty, reason: 'not heard until it ends');
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Updating {planner}…'), findsOneWidget);
      await tester.pump(kPlannerUpdateDuration);
      await tester.pump();
      expect(outcomes.done, [('target', 'voice-1', 'planner')]);
      expect(find.text('Played'), findsOneWidget);
      expect(find.text('Play'), findsNothing);
      expect(find.text('Already heard'), findsNothing);
      expect(find.text('Send note'), findsOneWidget);
      expect(container.read(committedCelebrationProvider)?.itemId, 'voice-1');
      expect(notifier.calls, contains(('target', 'voice-1')));
    });

    testWidgets('Already heard answers it with no confetti', (tester) async {
      final container = await open(tester, [rung('voice-1', voice: true)]);
      await tester.tap(find.byKey(const ValueKey('missed-heard-voice-1')));
      await tester.pump();
      await tester.pump(kPlannerUpdateDuration);
      await tester.pumpAndSettle();
      expect(outcomes.done, [('target', 'voice-1', 'planner')]);
      expect(find.text('Heard'), findsOneWidget);
      expect(container.read(committedCelebrationProvider), isNull);
    });

    testWidgets('after every voice card is answered, Next opens the alarm '
        'deck; each alarm is answered on its own card', (tester) async {
      final container = await open(tester, [
        rung('voice-1', voice: true),
        rung('alarm-1'),
        rung('alarm-2', title: 'Medicine'),
      ]);
      expect(find.byKey(const ValueKey('missed-deck-next')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('missed-heard-voice-1')));
      await tester.pump();
      await tester.pump(kPlannerUpdateDuration);
      await tester.pumpAndSettle();
      expect(find.text('Next: missed alarms (2)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('missed-deck-next')));
      await tester.pumpAndSettle();
      expect(find.text('Missed alarms'), findsOneWidget);
      expect(find.text('{planner} planned Morning walk for you'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Send note'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('missed-done-alarm-1')));
      await tester.pump();
      await tester.pump(kPlannerUpdateDuration);
      await tester.pumpAndSettle();
      expect(outcomes.done.last, ('target', 'alarm-1', 'planner'));
      expect(container.read(committedCelebrationProvider)?.itemId, 'alarm-1');
      // No bulk answer: the other card is still open.
      expect(find.byKey(const ValueKey('missed-deck-next')), findsNothing);

      await tester.drag(
        find.byKey(const ValueKey('missed-pages')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('missed-skip-alarm-2')));
      await tester.pump();
      await tester.pump(kPlannerUpdateDuration);
      await tester.pumpAndSettle();
      expect(outcomes.skipped.single.$2, 'alarm-2');
      expect(find.text('Skipped'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(popup, findsNothing);
    });

    testWidgets('✕ closes it without answering; a new missed alarm brings it '
        'back, and so does the Missed button', (tester) async {
      final container = await open(tester, [rung('voice-1', voice: true)]);
      await tester.tap(find.byKey(const ValueKey('missed-close')));
      await tester.pumpAndSettle();
      expect(popup, findsNothing);
      expect(outcomes.done, isEmpty);
      expect(outcomes.skipped, isEmpty);
      container.read(missedPopupTriggerProvider.notifier).open();
      await tester.pumpAndSettle();
      expect(popup, findsOneWidget);
    });

    testWidgets('a silenced or waiting alarm is answered directly, with the '
        'planner told; one that ran out keeps its unavailable fact', (
      tester,
    ) async {
      await open(
        tester,
        [rung('alarm-1'), _item()],
        events: [_event()],
      );
      // `item` ran out (timeout row): it is in the deck too.
      await tester.tap(find.byKey(const ValueKey('missed-done-alarm-1')));
      await tester.pump();
      await tester.pump(kPlannerUpdateDuration);
      await tester.pumpAndSettle();
      expect(outcomes.done, contains(('target', 'alarm-1', 'planner')));
      expect(notifier.calls, contains(('target', 'alarm-1')));
      await tester.drag(
        find.byKey(const ValueKey('missed-pages')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('missed-done-item')));
      await tester.pump();
      await tester.pump(kPlannerUpdateDuration);
      await tester.pumpAndSettle();
      expect(timeline.unavailable, contains(('target', 'item')));
      expect(outcomes.done, contains(('target', 'item', 'planner')));
    });

    testWidgets('repeated Play taps while the note loads fetch it once', (
      tester,
    ) async {
      final cache = _SlowCache();
      await open(tester, [rung('item', voice: true)], cache: cache);
      final play = find.byKey(const ValueKey('missed-play-item'));
      await tester.tap(play);
      await tester.pump();
      expect(find.text('Loading…'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await tester.tap(play, warnIfMissed: false);
        await tester.pump();
      }
      expect(cache.calls, 1);
      cache.finish();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(kPlannerUpdateDuration);
      await tester.pumpAndSettle();
      expect(outcomes.done, [('target', 'item', 'planner')]);
    });

    testWidgets('a note that cannot load records nothing and Play comes '
        'back', (tester) async {
      final cache = _SlowCache();
      await open(tester, [rung('item', voice: true)], cache: cache);
      await tester.tap(find.byKey(const ValueKey('missed-play-item')));
      await tester.pump();
      cache.fail();
      await tester.pumpAndSettle();
      expect(find.text("Couldn't load the voice note. Try again."), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      expect(outcomes.done, isEmpty);
    });

    testWidgets('Send note: sent once, then gone; the answers stay', (
      tester,
    ) async {
      await open(tester, [rung('alarm-1')]);
      await tester.tap(find.text('Send note'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('send-note-text')),
        'Running late',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-note-send')));
      await tester.pumpAndSettle();
      expect(replies.replies, ['target/alarm-1/Running late']);
      expect(find.text('Send note'), findsNothing);
      expect(find.text('Done'), findsOneWidget);
      // The note did not answer the alarm.
      expect(outcomes.done, isEmpty);
    });

    testWidgets('a self-plan has no one to send a note to', (tester) async {
      await open(tester, [rung('mine', createdBy: 'target')]);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Send note'), findsNothing);
    });

    testWidgets('hidden while an alarm rings, and under the app lock', (
      tester,
    ) async {
      await open(tester, [rung('alarm-1')], ringing: {'other'});
      await tester.pump(const Duration(seconds: 4));
      expect(popup, findsNothing);
      await open(tester, [rung('alarm-1')], locked: true);
      expect(popup, findsNothing);
      expect(find.text('Schedule'), findsOneWidget);
    });

    testWidgets('in the real app position (above the router): no error '
        'screen, the ✕ tooltip works, and Send note opens ON TOP of the '
        'pop-up', (tester) async {
      await open(tester, [rung('alarm-1')], aboveRouter: true);
      expect(tester.takeException(), isNull);
      expect(popup, findsOneWidget);
      await tester.longPress(find.byKey(const ValueKey('missed-close')));
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsOneWidget);
      await tester.tap(find.text('Send note'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const ValueKey('send-note-text')),
        'On my way',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-note-send')));
      await tester.pumpAndSettle();
      expect(replies.replies, ['target/alarm-1/On my way']);
      // The pop-up is still there, answers intact.
      expect(find.byKey(const ValueKey('missed-done-alarm-1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('missed-close')));
      await tester.pumpAndSettle();
      expect(popup, findsNothing);
      expect(find.text('Schedule'), findsOneWidget);
    });

    test('the answered state reads plainly', () {
      expect(missedAnswerLabel(MissedCardAnswer.played), 'Played');
      expect(missedAnswerLabel(MissedCardAnswer.heard), 'Heard');
      expect(missedAnswerLabel(MissedCardAnswer.done), 'Done');
      expect(missedAnswerLabel(MissedCardAnswer.skipped), 'Skipped');
    });
  });
}

final _occurred = DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true);

/// Lets fire-and-forget pushes and their follow-up resyncs finish.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

AlarmLifecycleEvent _event({
  AlarmLifecycleEventKind kind = AlarmLifecycleEventKind.timeout,
  bool outcomeRecorded = false,
  bool notificationDelivered = false,
  MissedAlarmReviewChoice? reviewChoice,
}) => AlarmLifecycleEvent(
  key: '${kind.name}:item:1000',
  itemId: 'item',
  occurredAtUtc: _occurred,
  kind: kind,
  outcomeRecorded: outcomeRecorded,
  notificationDelivered: notificationDelivered,
  reviewed: reviewChoice != null,
  reviewChoice: reviewChoice,
);

ScheduleItem _item({
  String id = 'item',
  String title = 'Morning walk',
  String createdByUid = 'planner',
  DateTime? unavailableAt,
  ScheduleOutcome? outcome,
  VoiceNoteMeta? voiceNote,
}) => ScheduleItem(
  id: id,
  voiceNote: voiceNote,
  targetUid: 'target',
  createdByUid: createdByUid,
  alarm: unavailableAt == null
      ? null
      : ScheduleAlarmTimeline(unavailableAt: unavailableAt),
  groupId: '',
  title: title,
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: DateTime.utc(2026, 9, 23, 8),
  status: ScheduleItemStatus.approved,
  outcome: outcome,
);

class _MemoryLifecycleStore implements AlarmLifecycleStore {
  _MemoryLifecycleStore(this.events);

  List<AlarmLifecycleEvent> events;

  @override
  void listen(Future<void> Function()? onChanged) {}

  @override
  Future<List<AlarmLifecycleEvent>> read() async => List.of(events);

  @override
  Future<void> markOutcomeRecorded(String key) async {
    _update(key, outcomeRecorded: true);
  }

  @override
  Future<void> markNotificationDelivered(String key) async {
    _update(key, notificationDelivered: true);
  }

  @override
  Future<void> markReviewed(String key) async {
    _update(key, reviewed: true);
  }

  @override
  Future<void> markReviewChoice(
    String key,
    MissedAlarmReviewChoice choice,
  ) async {
    _update(key, reviewed: true, reviewChoice: choice);
  }

  @override
  Future<void> markReviewNotificationDelivered(String key) async {
    _update(key, reviewNotificationDelivered: true);
  }

  @override
  Future<void> remove(String key) async {
    events = events.where((event) => event.key != key).toList();
  }

  void _update(
    String key, {
    bool? outcomeRecorded,
    bool? notificationDelivered,
    bool? reviewed,
    MissedAlarmReviewChoice? reviewChoice,
    bool? reviewNotificationDelivered,
  }) {
    events = [
      for (final event in events)
        event.key == key
            ? AlarmLifecycleEvent(
                key: event.key,
                itemId: event.itemId,
                occurredAtUtc: event.occurredAtUtc,
                kind: event.kind,
                outcomeRecorded: outcomeRecorded ?? event.outcomeRecorded,
                notificationDelivered:
                    notificationDelivered ?? event.notificationDelivered,
                reviewed: reviewed ?? event.reviewed,
                reviewChoice: reviewChoice ?? event.reviewChoice,
                reviewNotificationDelivered:
                    reviewNotificationDelivered ??
                    event.reviewNotificationDelivered,
              )
            : event,
    ];
  }
}

/// First-write-wins like the real transactions: once an item has an outcome,
/// later writes report `false`.
class _RecordingOutcomes implements MissedAlarmOutcomeRepository {
  _RecordingOutcomes({this.recorded = true, this.onWrite});

  final bool recorded;
  final void Function()? onWrite;
  final _decided = <String>{};
  final skipped = <(String, String, String)>[];
  final skipAnnouncedTo = <String?>[];
  final done = <(String, String, String)>[];
  final legacyDone = <(String, String, String)>[];

  bool _firstWrite(String itemId) {
    onWrite?.call();
    return recorded && _decided.add(itemId);
  }

  @override
  Future<bool> markDoneIfUnsettled(
    String targetUid,
    String itemId, {
    required String plannerUid,
  }) async {
    if (!_firstWrite(itemId)) return false;
    done.add((targetUid, itemId, plannerUid));
    return true;
  }

  @override
  Future<bool> markSkippedIfUnsettled(
    String targetUid,
    String itemId, {
    required String reason,
    String? plannerUid,
  }) async {
    if (!_firstWrite(itemId)) return false;
    skipped.add((targetUid, itemId, reason));
    skipAnnouncedTo.add(plannerUid);
    return true;
  }

  @override
  Future<bool> replaceMissedAlarmSkipWithDone(
    String targetUid,
    String itemId, {
    required String plannerUid,
  }) async {
    if (!_firstWrite(itemId)) return false;
    legacyDone.add((targetUid, itemId, plannerUid));
    return true;
  }
}

class _RecordingTimeline implements AlarmTimelineRepository {
  _RecordingTimeline({this.gate, this.onUnavailable});

  final Future<void>? gate;
  final void Function()? onUnavailable;
  final dismissed = <(String, String)>[];
  final unavailable = <(String, String)>[];
  final unavailableTimes = <DateTime>[];

  @override
  Future<void> recordDismissed(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) async {
    dismissed.add((targetUid, itemId));
  }

  @override
  Future<void> recordRang(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) async {}

  @override
  Future<void> recordUnavailable(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) async {
    if (gate != null) await gate;
    onUnavailable?.call();
    // Immutable once written, like the real transaction.
    if (unavailable.contains((targetUid, itemId))) return;
    unavailable.add((targetUid, itemId));
    unavailableTimes.add(atUtc);
  }
}

class _RecordingNotifier implements NotificationEventNotifier {
  _RecordingNotifier({List<bool> results = const [true]})
    : _results = List.of(results);

  final List<bool> _results;
  final calls = <(String, String)>[];

  @override
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async {
    await notifyConfirmed(event: event, targetUid: targetUid, itemId: itemId);
  }

  @override
  Future<NotificationDeliveryResult> notifyConfirmed({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async {
    calls.add((targetUid, itemId));
    final delivered = _results.isEmpty ? true : _results.removeAt(0);
    return NotificationDeliveryResult(
      delivered: delivered,
      reason: delivered ? 'sent' : 'no-tokens',
    );
  }
}

class _BlockingNotifier implements NotificationEventNotifier {
  _BlockingNotifier(this.gate);

  final Future<void> gate;

  @override
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async {
    await gate;
  }

  @override
  Future<NotificationDeliveryResult> notifyConfirmed({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async {
    await gate;
    return const NotificationDeliveryResult(delivered: true, reason: 'sent');
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

/// Item 32c-2 (2026-09-26): a voice-note alarm that had to ring the normal
/// ringtone is reported to the planner, then the native event is dropped.
void _voiceFallbackTests() {
  MissedAlarmService service(
    _MemoryLifecycleStore store,
    Future<bool> Function(String, String, DateTime)? report,
  ) => MissedAlarmService(
    store: store,
    outcomes: _RecordingOutcomes(),
    timeline: _RecordingTimeline(),
    notifier: _RecordingNotifier(),
    reportVoiceFallback: report,
  );

  test('a voice fallback is reported and the event dropped', () async {
    final store = _MemoryLifecycleStore([
      _event(kind: AlarmLifecycleEventKind.voiceFallback),
    ]);
    final reports = <(String, String, DateTime)>[];
    await service(store, (uid, itemId, at) async {
      reports.add((uid, itemId, at));
      return true;
    }).sync([_item()], 'target');
    expect(reports, [('target', 'item', _occurred)]);
    expect(store.events, isEmpty);
  });

  test('a report that could not be stored keeps the event for later', () async {
    final store = _MemoryLifecycleStore([
      _event(kind: AlarmLifecycleEventKind.voiceFallback),
    ]);
    await service(store, (_, _, _) async => false).sync([_item()], 'target');
    expect(store.events, hasLength(1));
  });

  test(
    'a voice fallback is never a missed-alarm review or an answer',
    () async {
      final store = _MemoryLifecycleStore([
        _event(kind: AlarmLifecycleEventKind.voiceFallback),
      ]);
      final outcomes = _RecordingOutcomes();
      final svc = MissedAlarmService(
        store: store,
        outcomes: outcomes,
        timeline: _RecordingTimeline(),
        notifier: _RecordingNotifier(),
        reportVoiceFallback: (_, _, _) async => true,
      );
      await svc.sync([_item()], 'target');
      expect(svc.reviews, isEmpty);
      expect(outcomes.done, isEmpty);
      expect(outcomes.skipped, isEmpty);
    },
  );

  test('the native kind string parses', () {
    final event = AlarmLifecycleEvent.fromMap({
      'key': 'k',
      'itemId': 'item',
      'occurredAtEpoch': 1000,
      'kind': 'voice_fallback',
    });
    expect(event?.kind, AlarmLifecycleEventKind.voiceFallback);
  });
}

const _voiceMeta = VoiceNoteMeta(
  durationMs: 8000,
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  sizeBytes: 9000,
);

class _Cache implements VoiceNoteCache {
  @override
  Future<String> ensure(ScheduleItem item) async => '/voice/${item.id}.m4a';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements VoicePlayer {
  /// How long the note plays before it reports the end.
  final Duration playFor = const Duration(seconds: 1);
  final played = <String>[];
  final _completed = StreamController<void>.broadcast();

  @override
  Future<void> play(String path) async {
    played.add(path);
    Timer(playFor, () => _completed.add(null));
  }

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get completed => _completed.stream;
}

/// A voice-note fetch the test finishes (or fails) by hand (R2).
class _SlowCache implements VoiceNoteCache {
  final _done = Completer<String>();
  var calls = 0;

  void finish() => _done.complete('/voice/item.m4a');
  void fail() => _done.completeError(StateError('offline'));

  @override
  Future<String> ensure(ScheduleItem item) {
    calls++;
    return _done.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records the R6 note writes.
class _ReplyRepo implements ScheduleRepository {
  final replies = <String>[];

  @override
  Future<void> sendReply(String targetUid, String itemId, String text) async =>
      replies.add('$targetUid/$itemId/$text');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The native alarm-sound bridge, as far as the pop-up asks: what rings now.
class _RingingSound implements AlarmSound {
  _RingingSound(this.ringing);

  final Set<String> ringing;

  @override
  Future<List<String>> ringingItems() async => ringing.toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
