import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/applock/application/app_lock_controller.dart';
import 'package:time_app/features/applock/application/app_lock_providers.dart';
import 'package:time_app/features/applock/data/app_lock_store.dart';
import 'package:time_app/features/applock/data/device_auth.dart';
import 'package:time_app/features/applock/data/secure_window.dart';
import 'package:time_app/features/celebrations/application/celebration_providers.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/reminders/application/missed_alarm_providers.dart';
import 'package:time_app/features/reminders/application/missed_alarm_service.dart';
import 'package:time_app/features/reminders/data/alarm_lifecycle_store.dart';
import 'package:time_app/features/reminders/data/alarm_timeline_repository.dart';
import 'package:time_app/features/reminders/presentation/missed_alarm_review_host.dart';
import 'package:time_app/features/scheduling/application/item_lapse_policy.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

void main() {
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

  testWidgets('multiple misses are reviewed one at a time with two actions', (
    tester,
  ) async {
    final store = _MemoryLifecycleStore([
      _event(),
      AlarmLifecycleEvent(
        key: 'timeout:item-2:2000',
        itemId: 'item-2',
        occurredAtUtc: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
        kind: AlarmLifecycleEventKind.timeout,
        outcomeRecorded: false,
        notificationDelivered: false,
        reviewed: false,
      ),
    ]);
    final service = MissedAlarmService(
      store: store,
      outcomes: _RecordingOutcomes(),
      timeline: _RecordingTimeline(),
      notifier: _RecordingNotifier(),
    );
    final lock = AppLockController(
      store: _NoopLockStore(),
      auth: _NoopDeviceAuth(),
      secureWindow: _NoopSecureWindow(),
      initiallyEnabled: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          missedAlarmServiceProvider.overrideWithValue(service),
          appLockControllerProvider.overrideWithValue(lock),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const MissedAlarmReviewHost(
            enabled: true,
            child: Scaffold(body: Text('Schedule')),
          ),
        ),
      ),
    );
    await service.sync([
      _item(),
      _item(id: 'item-2', title: 'Medicine'),
    ], 'target');
    await tester.pumpAndSettle();

    expect(find.textContaining('2 missed alarms'), findsOneWidget);
    expect(find.text('Morning walk'), findsOneWidget);
    expect(find.text('Medicine'), findsNothing);
    expect(find.text('Mark reviewed'), findsNothing);
    expect(find.text('Mark as Skipped'), findsOneWidget);
    expect(find.text('Mark as Done'), findsOneWidget);

    await tester.tap(find.text('Mark as Skipped'));
    await tester.pumpAndSettle();
    expect(find.text('Morning walk'), findsNothing);
    expect(find.text('Medicine'), findsOneWidget);

    await tester.tap(find.text('Mark as Done'));
    await tester.pumpAndSettle();
    expect(find.text('Missed alarm'), findsNothing);
    expect(find.text('Schedule'), findsOneWidget);
    expect(store.events.every((event) => event.reviewed), isTrue);

    // Only the popup's own committed Done celebrates, and it does so on save.
    final container = ProviderScope.containerOf(
      tester.element(find.text('Schedule')),
    );
    expect(container.read(committedCelebrationProvider)?.itemId, 'item-2');
  });

  testWidgets('review remains hidden while app lock is active', (tester) async {
    final service = MissedAlarmService(
      store: _MemoryLifecycleStore([_event()]),
      outcomes: _RecordingOutcomes(),
      timeline: _RecordingTimeline(),
      notifier: _RecordingNotifier(),
    );
    final lock = AppLockController(
      store: _NoopLockStore(),
      auth: _NoopDeviceAuth(),
      secureWindow: _NoopSecureWindow(),
      initiallyEnabled: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          missedAlarmServiceProvider.overrideWithValue(service),
          appLockControllerProvider.overrideWithValue(lock),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const MissedAlarmReviewHost(
            enabled: true,
            child: Scaffold(body: Text('Schedule')),
          ),
        ),
      ),
    );

    await service.sync([_item()], 'target');
    await tester.pump();

    expect(find.text('Missed alarm'), findsNothing);
    expect(find.text('Schedule'), findsOneWidget);
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
}) => ScheduleItem(
  id: id,
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
  _RecordingOutcomes({this.recorded = true});

  final bool recorded;
  final _decided = <String>{};
  final skipped = <(String, String, String)>[];
  final done = <(String, String, String)>[];
  final legacyDone = <(String, String, String)>[];

  bool _firstWrite(String itemId) => recorded && _decided.add(itemId);

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
  }) async {
    if (!_firstWrite(itemId)) return false;
    skipped.add((targetUid, itemId, reason));
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
