import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/reminders/application/alarm_timeline_providers.dart';
import 'package:time_app/features/reminders/application/alarm_timeline_service.dart';
import 'package:time_app/features/reminders/application/missed_alarm_providers.dart';
import 'package:time_app/features/reminders/application/reminder_providers.dart';
import 'package:time_app/features/reminders/application/reminder_service.dart';
import 'package:time_app/features/reminders/data/alarm_sound.dart';
import 'package:time_app/features/reminders/data/alarm_timeline_repository.dart';
import 'package:time_app/features/reminders/data/alarm_lifecycle_store.dart';
import 'package:time_app/features/reminders/data/reminder_audit_log.dart';
import 'package:time_app/features/reminders/data/reminder_mirror_store.dart';
import 'package:time_app/features/reminders/data/reminder_scheduler.dart';
import 'package:time_app/features/reminders/domain/reminder.dart';
import 'package:time_app/features/reminders/presentation/alarm_screen.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// The alarm screen's PLAYBACK wiring — the one bit of the foreground-service
/// alarm that lives in Dart. The service, the wake lock and the audio are native
/// and can only be proven on a device; what Dart owns is: start the sound and
/// silence the notification on mount, stop the sound on dismiss. That is what
/// this pins.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  ScheduleItem item({String createdByUid = 'planner'}) => ScheduleItem(
    id: 'a',
    targetUid: 'me',
    createdByUid: createdByUid,
    groupId: '',
    title: 'Morning run',
    localWallTime: '',
    timezone: 'Asia/Kolkata',
    scheduledInstantUtc: DateTime.utc(2030, 1, 1, 3, 30),
    status: ScheduleItemStatus.approved,
  );

  Widget harness(
    _FakeAlarmSound sound,
    _FakeScheduler scheduler, {
    _FakeAlarmTimelineRepository? timeline,
    _FakeAlarmKeyEvents? keys,
    Stream<List<ScheduleItem>>? items,
    Stream<UserProfile?> Function(String uid)? profiles,
    List<AlarmLifecycleEvent> lifecycle = const [],
  }) {
    final service = ReminderService(
      scheduler: scheduler,
      store: InMemoryReminderMirrorStore(),
    );
    final router = GoRouter(
      initialLocation: '/alarm',
      routes: [
        GoRoute(
          path: '/alarm',
          builder: (_, _) => const AlarmScreen(itemId: 'a'),
        ),
        GoRoute(
          // Post-S5: a reminder Dismiss lands on the Plan pillar
          // (`/plan?item=<id>`), which forwards the highlight into My Schedule.
          path: '/plan',
          builder: (_, _) => const Scaffold(body: Text('PLAN')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        currentUidProvider.overrideWithValue('me'),
        alarmSoundProvider.overrideWithValue(sound),
        alarmKeyEventsProvider.overrideWithValue(keys ?? _FakeAlarmKeyEvents()),
        alarmTimelineServiceProvider.overrideWithValue(
          AlarmTimelineService(
            repository: timeline ?? _FakeAlarmTimelineRepository(),
            audit: const ReminderAuditLog(),
          ),
        ),
        reminderServiceProvider.overrideWithValue(service),
        alarmLifecycleStoreProvider.overrideWithValue(
          _LifecycleStore(lifecycle),
        ),
        allItemsAsTargetProvider.overrideWith(
          (ref) => items ?? Stream.value([item()]),
        ),
        profileByUidProvider.overrideWith(
          (ref, uid) =>
              profiles?.call(uid) ??
              Stream.value(
                uid == 'planner'
                    ? const UserProfile(
                        uid: 'planner',
                        name: '{planner}',
                        homeTimezone: 'Asia/Kolkata',
                      )
                    : null,
              ),
        ),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    );
  }

  String headlineText(WidgetTester t) =>
      t.widget<Text>(find.byKey(const ValueKey('alarm-headline'))).data!;

  testWidgets('starts the alarm sound on mount and shows the item', (t) async {
    final sound = _FakeAlarmSound();
    await t.pumpWidget(harness(sound, _FakeScheduler()));
    await t.pump(); // let the post-frame callback run
    await t.pump();
    expect(sound.starts, 1);
    expect(sound.stops, 0);
    expect(headlineText(t), '{planner} planned Morning run for you');
  });

  testWidgets('reads as ONE centered bold sentence (directed 2026-09-25)', (
    t,
  ) async {
    await t.pumpWidget(harness(_FakeAlarmSound(), _FakeScheduler()));
    await t.pumpAndSettle();

    final headline = t.widget<Text>(
      find.byKey(const ValueKey('alarm-headline')),
    );
    expect(headline.data, '{planner} planned Morning run for you');
    expect(headline.textAlign, TextAlign.center);
    expect(headline.style?.fontWeight, FontWeight.bold);
    // The old two-line layout is gone.
    expect(find.byKey(const ValueKey('alarm-planner-name')), findsNothing);
    expect(find.byKey(const ValueKey('alarm-task-name')), findsNothing);
  });

  testWidgets('a self-plan reads "You planned …"', (t) async {
    await t.pumpWidget(
      harness(
        _FakeAlarmSound(),
        _FakeScheduler(),
        items: Stream.value([item(createdByUid: 'me')]),
      ),
    );
    await t.pumpAndSettle();

    expect(headlineText(t), 'You planned Morning run');
  });

  testWidgets(
    'no placeholder flashes: the delivered sentence shows before the item loads',
    (t) async {
      // Regression (2026-09-25): on the lock screen the alarm showed
      // "Reminder" / "Planner" for a moment before the real names.
      final items = StreamController<List<ScheduleItem>>();
      addTearDown(items.close);
      final sound = _FakeAlarmSound(
        delivered: '{planner} planned Morning run for you',
      );
      await t.pumpWidget(harness(sound, _FakeScheduler(), items: items.stream));

      // Before anything resolves: blank, never a wrong word.
      expect(headlineText(t), '');
      expect(find.text('Reminder'), findsNothing);
      expect(find.text('Planner'), findsNothing);

      await t.pump(); // post-frame: the delivered sentence arrives
      await t.pump();
      expect(headlineText(t), '{planner} planned Morning run for you');

      items.add([item()]);
      await t.pumpAndSettle();
      expect(headlineText(t), '{planner} planned Morning run for you');
      expect(find.text('Reminder'), findsNothing);
    },
  );

  testWidgets('an unresolved planner never shows a placeholder name', (
    t,
  ) async {
    final profiles = StreamController<UserProfile?>();
    addTearDown(profiles.close);
    await t.pumpWidget(
      harness(
        _FakeAlarmSound(delivered: '{planner} planned Morning run for you'),
        _FakeScheduler(),
        profiles: (_) => profiles.stream,
      ),
    );
    await t.pump();
    await t.pump();

    // Item loaded, planner profile still loading: keep the delivered sentence.
    expect(headlineText(t), '{planner} planned Morning run for you');
    expect(find.textContaining('Planner'), findsNothing);
  });

  testWidgets('the UI-fallback start carries the sentence to native', (
    t,
  ) async {
    final sound = _FakeAlarmSound(
      delivered: '{planner} planned Morning run for you',
    );
    await t.pumpWidget(harness(sound, _FakeScheduler()));
    await t.pumpAndSettle();

    expect(
      sound.startHeadlines.single,
      '{planner} planned Morning run for you',
    );
  });

  testWidgets('cancels the fired notification on mount (no double tone)', (
    t,
  ) async {
    final scheduler = _FakeScheduler();
    await t.pumpWidget(harness(_FakeAlarmSound(), scheduler));
    await t.pump();
    // dismiss() cancels the OS notification for the item — its id falls back to
    // the deterministic hash when the mirror is empty.
    expect(scheduler.cancelled, contains(reminderNotificationId('a')));
  });

  testWidgets('claims service playback before releasing notification owner', (
    t,
  ) async {
    final claimReachedNative = Completer<void>();
    final sound = _FakeAlarmSound(startGate: claimReachedNative);
    final scheduler = _FakeScheduler();

    await t.pumpWidget(harness(sound, scheduler));
    await t.pump();

    expect(sound.starts, 1);
    expect(
      scheduler.cancelled,
      isEmpty,
      reason: 'notification ownership must survive until UI ownership lands',
    );

    claimReachedNative.complete();
    await t.pump();
    expect(scheduler.cancelled, contains(reminderNotificationId('a')));
  });

  testWidgets('Dismiss stops the sound and leaves for My Schedule', (t) async {
    final sound = _FakeAlarmSound();
    final timeline = _FakeAlarmTimelineRepository();
    await t.pumpWidget(harness(sound, _FakeScheduler(), timeline: timeline));
    await t.pump();

    await t.tap(find.text('Dismiss'));
    await t.pumpAndSettle();

    expect(sound.stops, 1);
    expect(timeline.rang, ['a']);
    expect(timeline.dismissed, ['a']);
    expect(find.text('PLAN'), findsOneWidget);
  });

  // R6 (2026-10-02): a ringing VOICE note can be answered with a note.
  ScheduleItem voiceItem() => ScheduleItem(
    id: 'a',
    targetUid: 'me',
    createdByUid: 'planner',
    groupId: '',
    title: 'Voice alarm',
    localWallTime: '',
    timezone: 'Asia/Kolkata',
    scheduledInstantUtc: DateTime.utc(2030, 1, 1, 3, 30),
    status: ScheduleItemStatus.approved,
    voiceNote: const VoiceNoteMeta(
      durationMs: 5000,
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      sizeBytes: 100,
    ),
  );
  final dismissReply = find.byKey(const ValueKey('alarm-dismiss-reply'));

  testWidgets('a default alarm offers Dismiss only', (t) async {
    await t.pumpWidget(harness(_FakeAlarmSound(), _FakeScheduler()));
    await t.pumpAndSettle();
    expect(find.text('Dismiss'), findsOneWidget);
    expect(dismissReply, findsNothing);
  });

  testWidgets('a voice note: Dismiss & reply stops it, records the '
      'dismissal, then asks for the optional note before leaving', (t) async {
    final sound = _FakeAlarmSound();
    final timeline = _FakeAlarmTimelineRepository();
    await t.pumpWidget(
      harness(
        sound,
        _FakeScheduler(),
        timeline: timeline,
        items: Stream.value([voiceItem()]),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Dismiss'), findsOneWidget);
    expect(find.text('Dismiss & reply'), findsOneWidget);

    await t.tap(dismissReply);
    await t.pumpAndSettle();
    expect(sound.stops, 1);
    expect(timeline.dismissed, ['a']);
    expect(
      find.text('Optional: send a note to {planner} about this voice note.'),
      findsOneWidget,
    );
    expect(find.text('PLAN'), findsNothing);

    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('PLAN'), findsOneWidget);
  });

  testWidgets('Volume Down silence leaves through the same dismiss path', (
    t,
  ) async {
    final sound = _FakeAlarmSound();
    final timeline = _FakeAlarmTimelineRepository();
    final keys = _FakeAlarmKeyEvents();
    await t.pumpWidget(
      harness(sound, _FakeScheduler(), timeline: timeline, keys: keys),
    );
    await t.pump();

    await keys.silence();
    await t.pumpAndSettle();

    expect(sound.stops, 1);
    expect(timeline.dismissed, ['a']);
    expect(find.text('PLAN'), findsOneWidget);
  });

  // ---- 2026-09-27: an alarm that already ended never shows Dismiss ----

  AlarmLifecycleEvent timeoutRow() => AlarmLifecycleEvent(
    key: 'k',
    itemId: 'a',
    occurredAtUtc: DateTime.utc(2030, 1, 1, 3, 31),
    kind: AlarmLifecycleEventKind.timeout,
    outcomeRecorded: false,
    notificationDelivered: false,
    reviewed: false,
  );

  testWidgets('opened after the ring cap: no tone, no Dismiss, lands on Plan', (
    t,
  ) async {
    final sound = _FakeAlarmSound();
    final timeline = _FakeAlarmTimelineRepository();
    await t.pumpWidget(
      harness(
        sound,
        _FakeScheduler(),
        timeline: timeline,
        lifecycle: [timeoutRow()],
      ),
    );
    await t.pumpAndSettle();
    expect(sound.starts, 0);
    expect(find.text('Dismiss'), findsNothing);
    expect(find.text('PLAN'), findsOneWidget);
  });

  // 2026-10-04: an alarm opened after its whole 25-minute ring cycle, with
  // nothing ringing, never starts a tone; it ends as missed. Between rings
  // it stays quiet and says when it rings again.
  ScheduleItem dueAgo(Duration ago) => ScheduleItem(
    id: 'a',
    targetUid: 'me',
    createdByUid: 'planner',
    groupId: '',
    title: 'Morning run',
    localWallTime: '',
    timezone: 'Asia/Kolkata',
    scheduledInstantUtc: DateTime.now().toUtc().subtract(ago),
    status: ScheduleItemStatus.approved,
  );

  testWidgets(
    'opened a day late and not in the queue: no tone, missed, lands on Plan',
    (t) async {
      final sound = _FakeAlarmSound();
      await t.pumpWidget(
        harness(
          sound,
          _FakeScheduler(),
          items: Stream.value([dueAgo(const Duration(hours: 25))]),
        ),
      );
      await t.pumpAndSettle();
      expect(sound.starts, 0);
      expect(sound.missedLate, ['a']);
      expect(find.text('Dismiss'), findsNothing);
      expect(find.text('PLAN'), findsOneWidget);
    },
  );

  testWidgets('opened while waiting for a repeat: silent, says when, Dismiss '
      'offered (2026-10-05)', (t) async {
    final sound = _FakeAlarmSound()
      ..nextRing = DateTime.now().toUtc().add(const Duration(minutes: 40));
    await t.pumpWidget(
      harness(
        sound,
        _FakeScheduler(),
        items: Stream.value([dueAgo(const Duration(minutes: 7))]),
      ),
    );
    await t.pumpAndSettle();
    expect(sound.starts, 0, reason: 'the native queue rings it');
    expect(sound.missedLate, isEmpty);
    expect(find.byKey(const ValueKey('alarm-quiet')), findsOneWidget);
    expect(find.textContaining('Rings again at'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
  });

  testWidgets('opened after its time but not in the queue: rings', (t) async {
    final sound = _FakeAlarmSound();
    await t.pumpWidget(
      harness(
        sound,
        _FakeScheduler(),
        items: Stream.value([dueAgo(const Duration(minutes: 12))]),
      ),
    );
    await t.pumpAndSettle();
    expect(sound.starts, 1);
    expect(sound.missedLate, isEmpty);
  });

  testWidgets('late but still ringing natively: shows and keeps ringing', (
    t,
  ) async {
    final sound = _FakeAlarmSound(ringing: 'a');
    await t.pumpWidget(
      harness(
        sound,
        _FakeScheduler(),
        items: Stream.value([dueAgo(const Duration(minutes: 30))]),
      ),
    );
    await t.pumpAndSettle();
    expect(sound.starts, 1);
    expect(sound.missedLate, isEmpty);
    expect(find.text('Dismiss'), findsOneWidget);
  });

  testWidgets('a few minutes late it still rings (ring 1)', (t) async {
    final sound = _FakeAlarmSound();
    await t.pumpWidget(
      harness(
        sound,
        _FakeScheduler(),
        items: Stream.value([dueAgo(const Duration(minutes: 3))]),
      ),
    );
    await t.pumpAndSettle();
    expect(sound.starts, 1);
    expect(sound.missedLate, isEmpty);
  });

  // 2026-10-04: several alarms at once. Each is listed with its own Dismiss.
  ScheduleItem other(String id, String title) => ScheduleItem(
    id: id,
    targetUid: 'me',
    createdByUid: 'planner',
    groupId: '',
    title: title,
    localWallTime: '',
    timezone: 'Asia/Kolkata',
    scheduledInstantUtc: DateTime.now().toUtc(),
    status: ScheduleItemStatus.approved,
  );

  testWidgets('other alarms ringing too are listed, each with Dismiss', (
    t,
  ) async {
    final sound = _FakeAlarmSound(ringingList: ['b', 'a']);
    final scheduler = _FakeScheduler();
    await t.pumpWidget(
      harness(
        sound,
        scheduler,
        items: Stream.value([
          dueAgo(const Duration(seconds: 10)),
          other('b', 'Stretch'),
        ]),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Also ringing'), findsOneWidget);
    expect(find.byKey(const ValueKey('alarm-also-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('alarm-also-a')), findsNothing);
    expect(find.byKey(const ValueKey('alarm-dismiss-all')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('alarm-also-dismiss-b')));
    await t.pumpAndSettle();
    expect(sound.stopped, ['b']);
    expect(find.text('Also ringing'), findsNothing);
    expect(find.text('Dismiss'), findsOneWidget, reason: 'this alarm stays');
  });

  testWidgets('Dismiss all stops every ringing alarm and leaves', (t) async {
    final sound = _FakeAlarmSound(ringingList: ['b', 'c', 'a']);
    await t.pumpWidget(
      harness(
        sound,
        _FakeScheduler(),
        items: Stream.value([
          dueAgo(const Duration(seconds: 10)),
          other('b', 'Stretch'),
          other('c', 'Water'),
        ]),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('alarm-dismiss-all')));
    await t.pumpAndSettle();
    expect(sound.stopped.toSet(), {'a', 'b', 'c'});
    expect(find.text('PLAN'), findsOneWidget);
  });

  test('a repeat is labelled with its ring; a new alarm is not', () {
    expect(alarmRingLabel(1), isNull);
    expect(alarmRingLabel(2), 'Reminder 2 of 3');
    expect(alarmRingLabel(3), 'Reminder 3 of 3');
  });

  test('the ring count in words matches the native queue', () {
    final native = File(
      'android/app/src/main/kotlin/com/timeapp/time_app/reminders/'
      'RingQueuePolicy.kt',
    ).readAsStringSync();
    expect(native, contains('const val RINGS = $kAlarmRingCount'));
  });

  testWidgets('a cold-started repeat names who, what, when and which ring '
      'before the item stream loads (2026-10-05)', (t) async {
    final sound = _FakeAlarmSound(ringingList: ['a'])
      ..details = [
        RingingAlarm(
          itemId: 'a',
          headline: '{planner} planned Morning run for you',
          scheduledAtUtc: DateTime.utc(2030, 1, 1, 3, 30),
          ring: 2,
          voice: false,
          sounding: true,
        ),
      ];
    await t.pumpWidget(
      harness(
        sound,
        _FakeScheduler(),
        items: const Stream<List<ScheduleItem>>.empty(),
      ),
    );
    await t.pump();
    await t.pump(const Duration(seconds: 3));
    expect(find.text('Reminder 2 of 3'), findsOneWidget);
    expect(headlineText(t), '{planner} planned Morning run for you');
    expect(find.byKey(const ValueKey('alarm-planned-at')), findsOneWidget);
  });

  testWidgets('a batch lists every alarm with its time and ring, and marks '
      'the one playing (2026-10-05)', (t) async {
    final sound = _FakeAlarmSound(ringingList: ['a', 'b'])
      ..details = [
        RingingAlarm(
          itemId: 'a',
          headline: '{planner} sent you a voice alarm',
          scheduledAtUtc: DateTime.utc(2030, 1, 1, 3, 30),
          ring: 2,
          voice: true,
          sounding: false,
        ),
        RingingAlarm(
          itemId: 'b',
          headline: 'Friend sent you a voice alarm',
          scheduledAtUtc: DateTime.utc(2030, 1, 1, 3, 31),
          ring: 3,
          voice: true,
          sounding: true,
        ),
      ];
    await t.pumpWidget(harness(sound, _FakeScheduler()));
    await t.pump();
    await t.pump(const Duration(seconds: 3));
    expect(find.text('Also ringing'), findsOneWidget);
    expect(find.text('Friend sent you a voice alarm'), findsOneWidget);
    expect(find.textContaining('Reminder 3 of 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('alarm-now-playing-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('alarm-now-playing-a')), findsNothing);
    await t.tap(find.text('Dismiss').first);
    await t.pumpAndSettle();
  });

  test('alsoRingingIds leaves out this alarm and keeps the order', () {
    expect(alsoRingingIds(['b', 'a', 'c'], 'a'), ['b', 'c']);
    expect(alsoRingingIds(const [], 'a'), isEmpty);
  });

  test('alarmScreenPhase follows the native queue (2026-10-05)', () {
    final due = DateTime.utc(2030, 1, 1, 9);
    final i = dueAgo(Duration.zero);
    final at = ScheduleItem(
      id: i.id,
      targetUid: i.targetUid,
      createdByUid: i.createdByUid,
      groupId: i.groupId,
      title: i.title,
      localWallTime: i.localWallTime,
      timezone: i.timezone,
      scheduledInstantUtc: due,
      status: i.status,
    );
    AlarmScreenPhase phase(Duration after, {Duration? nextIn}) =>
        alarmScreenPhase(
          at,
          nowUtc: due.add(after),
          nextRingAtUtc: nextIn == null ? null : due.add(after).add(nextIn),
        );
    // Waiting in the queue for a repeat, however far it was pushed back.
    expect(
      phase(const Duration(minutes: 7), nextIn: const Duration(minutes: 40)),
      AlarmScreenPhase.waiting,
    );
    // Due now in the queue.
    expect(
      phase(const Duration(minutes: 7), nextIn: Duration.zero),
      AlarmScreenPhase.ring,
    );
    // Not in the queue: rung (it joins as a new alarm) unless a day old.
    expect(phase(Duration.zero), AlarmScreenPhase.ring);
    expect(phase(const Duration(hours: 3)), AlarmScreenPhase.ring);
    expect(phase(const Duration(hours: 24)), AlarmScreenPhase.over);
  });

  testWidgets('an item already marked unavailable leaves too', (t) async {
    final sound = _FakeAlarmSound();
    final missed = ScheduleItem(
      id: 'a',
      targetUid: 'me',
      createdByUid: 'planner',
      groupId: '',
      title: 'Morning run',
      localWallTime: '',
      timezone: 'Asia/Kolkata',
      scheduledInstantUtc: DateTime.utc(2030, 1, 1, 3, 30),
      status: ScheduleItemStatus.approved,
      alarm: ScheduleAlarmTimeline(
        rangAt: DateTime.utc(2030, 1, 1, 3, 30),
        unavailableAt: DateTime.utc(2030, 1, 1, 3, 31),
      ),
    );
    await t.pumpWidget(
      harness(sound, _FakeScheduler(), items: Stream.value([missed])),
    );
    await t.pumpAndSettle();
    expect(find.text('Dismiss'), findsNothing);
    expect(find.text('PLAN'), findsOneWidget);
  });

  test('alarmHasEnded: only real endings count', () {
    final live = item();
    expect(alarmHasEnded(itemId: 'a', item: live, events: const []), isFalse);
    expect(alarmHasEnded(itemId: 'a', item: null, events: const []), isFalse);
    expect(
      alarmHasEnded(itemId: 'a', item: null, events: [timeoutRow()]),
      isTrue,
    );
    // Another item's timeout is not this alarm's.
    expect(
      alarmHasEnded(itemId: 'other', item: null, events: [timeoutRow()]),
      isFalse,
    );
  });
}

class _FakeAlarmKeyEvents implements AlarmKeyEvents {
  Future<void> Function()? handler;

  @override
  void listen(Future<void> Function()? onVolumeSilenced) {
    handler = onVolumeSilenced;
  }

  Future<void> silence() async => handler?.call();
}

class _FakeAlarmTimelineRepository implements AlarmTimelineRepository {
  final rang = <String>[];
  final dismissed = <String>[];
  final unavailable = <String>[];

  @override
  Future<void> recordRang(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) async {
    rang.add(itemId);
  }

  @override
  Future<void> recordDismissed(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) async {
    dismissed.add(itemId);
  }

  @override
  Future<void> recordUnavailable(
    String targetUid,
    String itemId,
    DateTime atUtc,
  ) async {
    unavailable.add(itemId);
  }
}

class _FakeAlarmSound implements AlarmSound {
  _FakeAlarmSound({
    this.startGate,
    this.delivered,
    this.ringing,
    this.ringingList = const [],
  });

  /// Every alarm the native service is ringing now (2026-10-04).
  List<String> ringingList;

  /// The native queue's forecast for the next ring (2026-10-05).
  DateTime? nextRing;

  /// The segment's rows as native reports them (2026-10-05); derived from
  /// [ringingList] when not set.
  List<RingingAlarm>? details;

  @override
  Future<List<RingingAlarm>> segmentDetails() async {
    if (details != null) return details!;
    final ids = await ringingItems();
    return [
      for (final id in ids)
        RingingAlarm(
          itemId: id,
          headline: '',
          scheduledAtUtc: null,
          ring: 1,
          voice: false,
          sounding: id == (ringing ?? ids.last),
        ),
    ];
  }

  final stopped = <String>[];

  final Completer<void>? startGate;
  final String? delivered;

  /// The item the native service is ringing now (R5).
  final String? ringing;
  final missedLate = <String>[];
  int starts = 0;
  int stops = 0;
  final startHeadlines = <String>[];

  @override
  Future<DateTime?> nextRingAt(String itemId) async => nextRing;

  @override
  Future<void> start(
    String itemId, {
    String headline = '',
    DateTime? scheduledAtUtc,
  }) async {
    starts++;
    startHeadlines.add(headline);
    if (startGate != null) await startGate!.future;
  }

  @override
  Future<String?> headline(String itemId) async => delivered;

  @override
  Future<void> stop(String itemId) async {
    stops++;
    stopped.add(itemId);
    ringingList = [
      for (final id in ringingList)
        if (id != itemId) id,
    ];
  }

  @override
  Future<List<String>> ringingItems() async =>
      ringingList.isEmpty && ringing != null ? [ringing!] : ringingList;

  @override
  Future<String?> ringingItem() async => ringing;

  @override
  Future<void> missLate(String itemId, {String headline = ''}) async =>
      missedLate.add(itemId);

  @override
  void onRinging(void Function(String itemId)? listener) {}
}

class _FakeScheduler implements ReminderScheduler {
  final cancelled = <int>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> schedule(ReminderRequest request, int notificationId) async =>
      true;

  @override
  Future<void> cancel(int notificationId) async =>
      cancelled.add(notificationId);

  @override
  Future<void> cancelAll() async {}
}

/// The native lifecycle rows, as the alarm screen reads them on mount.
class _LifecycleStore implements AlarmLifecycleStore {
  _LifecycleStore(this.events);

  final List<AlarmLifecycleEvent> events;

  @override
  Future<List<AlarmLifecycleEvent>> read() async => events;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
