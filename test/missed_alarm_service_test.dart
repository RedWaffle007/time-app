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

  test(
    'timeout records skipped outcome, notifies planner, and awaits review',
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

      expect(outcomes.skipped, [('target', 'item', kMissedAlarmSkipReason)]);
      expect(outcomes.skipTimes, [
        DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      ]);
      expect(notifier.calls, [('target', 'item')]);
      expect(service.reviews.single.item.id, 'item');
      expect(store.events.single.outcomeRecorded, isTrue);
      expect(store.events.single.notificationDelivered, isTrue);
    },
  );

  test('manual outcome wins a timeout race and is never overwritten', () async {
    final store = _MemoryLifecycleStore([_event()]);
    final outcomes = _RecordingOutcomes();
    final service = MissedAlarmService(
      store: store,
      outcomes: outcomes,
      timeline: _RecordingTimeline(),
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
    expect(store.events, isEmpty);
    expect(service.reviews, isEmpty);
  });

  test('alarm timeout supersedes only the automatic end-of-day skip', () async {
    final store = _MemoryLifecycleStore([_event()]);
    final outcomes = _RecordingOutcomes();
    final service = MissedAlarmService(
      store: store,
      outcomes: outcomes,
      timeline: _RecordingTimeline(),
      notifier: _RecordingNotifier(),
    );

    await service.sync([
      _item(
        outcome: const ScheduleOutcome(
          result: OutcomeResult.skipped,
          skipReason: kLapsedSkipReason,
        ),
      ),
    ], 'target');

    expect(outcomes.replaced, [
      ('target', 'item', kLapsedSkipReason, kMissedAlarmSkipReason),
    ]);
    expect(store.events.single.outcomeRecorded, isTrue);
    expect(service.reviews, hasLength(1));
  });

  test(
    'a concurrent outcome makes the automatic transaction back off',
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

      expect(outcomes.skipped, hasLength(1));
      expect(store.events.single.outcomeRecorded, isFalse);
      expect(notifier.calls, isEmpty);
      expect(service.reviews, isEmpty);
    },
  );

  test('volume silence is reconciled as dismissal without skipping', () async {
    final store = _MemoryLifecycleStore([
      _event(kind: AlarmLifecycleEventKind.volumeSilenced),
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
    expect(outcomes.skipped, isEmpty);
    expect(store.events, isEmpty);
  });

  test(
    'failed planner notification remains durable and retries after review',
    () async {
      final store = _MemoryLifecycleStore([_event()]);
      final notifier = _RecordingNotifier(results: [false, true]);
      final service = MissedAlarmService(
        store: store,
        outcomes: _RecordingOutcomes(),
        timeline: _RecordingTimeline(),
        notifier: notifier,
      );

      await service.sync([_item()], 'target');
      await service.markAllReviewed();
      expect(store.events.single.reviewed, isTrue);

      await service.sync([
        _item(
          outcome: const ScheduleOutcome(
            result: OutcomeResult.skipped,
            skipReason: kMissedAlarmSkipReason,
          ),
        ),
      ], 'target');

      expect(notifier.calls, [('target', 'item'), ('target', 'item')]);
      expect(store.events, isEmpty);
      expect(service.reviews, isEmpty);
    },
  );

  testWidgets('next open shows every missed task and marks them reviewed', (
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

    expect(find.text('2 missed alarms'), findsOneWidget);
    expect(find.text('Morning walk'), findsOneWidget);
    expect(find.text('Medicine'), findsOneWidget);

    await tester.tap(find.text('Mark reviewed'));
    await tester.pumpAndSettle();
    expect(find.text('2 missed alarms'), findsNothing);
    expect(find.text('Schedule'), findsOneWidget);
    expect(store.events.every((event) => event.reviewed), isTrue);
  });
}

AlarmLifecycleEvent _event({
  AlarmLifecycleEventKind kind = AlarmLifecycleEventKind.timeout,
}) => AlarmLifecycleEvent(
  key: '${kind.name}:item:1000',
  itemId: 'item',
  occurredAtUtc: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
  kind: kind,
  outcomeRecorded: false,
  notificationDelivered: false,
  reviewed: false,
);

ScheduleItem _item({
  String id = 'item',
  String title = 'Morning walk',
  ScheduleOutcome? outcome,
}) => ScheduleItem(
  id: id,
  targetUid: 'target',
  createdByUid: 'planner',
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
  Future<void> remove(String key) async {
    events = events.where((event) => event.key != key).toList();
  }

  void _update(
    String key, {
    bool? outcomeRecorded,
    bool? notificationDelivered,
    bool? reviewed,
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
              )
            : event,
    ];
  }
}

class _RecordingOutcomes implements MissedAlarmOutcomeRepository {
  _RecordingOutcomes({this.recorded = true});

  final bool recorded;
  final skipped = <(String, String, String?)>[];
  final skipTimes = <DateTime>[];
  final replaced = <(String, String, String, String)>[];

  @override
  Future<bool> markSkippedIfUnsettled(
    String targetUid,
    String itemId, {
    required String reason,
    required DateTime atUtc,
  }) async {
    skipped.add((targetUid, itemId, reason));
    skipTimes.add(atUtc);
    return recorded;
  }

  @override
  Future<bool> replaceAutomaticSkipIfMatches(
    String targetUid,
    String itemId, {
    required String expectedReason,
    required String reason,
    required DateTime atUtc,
  }) async {
    replaced.add((targetUid, itemId, expectedReason, reason));
    return recorded;
  }
}

class _RecordingTimeline implements AlarmTimelineRepository {
  final dismissed = <(String, String)>[];

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
