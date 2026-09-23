import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/reminders/application/alarm_timeline_providers.dart';
import 'package:time_app/features/reminders/application/alarm_timeline_service.dart';
import 'package:time_app/features/reminders/application/reminder_providers.dart';
import 'package:time_app/features/reminders/application/reminder_service.dart';
import 'package:time_app/features/reminders/data/alarm_sound.dart';
import 'package:time_app/features/reminders/data/alarm_timeline_repository.dart';
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

  ScheduleItem item() => ScheduleItem(
    id: 'a',
    targetUid: 'me',
    createdByUid: 'me',
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
        alarmTimelineServiceProvider.overrideWithValue(
          AlarmTimelineService(
            repository: timeline ?? _FakeAlarmTimelineRepository(),
            audit: const ReminderAuditLog(),
          ),
        ),
        reminderServiceProvider.overrideWithValue(service),
        allItemsAsTargetProvider.overrideWith((ref) => Stream.value([item()])),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    );
  }

  testWidgets('starts the alarm sound on mount and shows the item', (t) async {
    final sound = _FakeAlarmSound();
    await t.pumpWidget(harness(sound, _FakeScheduler()));
    await t.pump(); // let the post-frame callback run
    expect(sound.starts, 1);
    expect(sound.stops, 0);
    expect(find.text('Morning run'), findsOneWidget);
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
}

class _FakeAlarmTimelineRepository implements AlarmTimelineRepository {
  final rang = <String>[];
  final dismissed = <String>[];

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
}

class _FakeAlarmSound implements AlarmSound {
  int starts = 0;
  int stops = 0;

  @override
  Future<void> start(String itemId) async => starts++;

  @override
  Future<void> stop(String itemId) async => stops++;
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
