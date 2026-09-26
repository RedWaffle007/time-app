import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/features/notifications/data/foreground_push_presenter.dart';
import 'package:time_app/features/plan/application/plan_intent.dart';
import 'package:time_app/features/reminders/data/local_notifications_reminder_scheduler.dart';
import 'package:time_app/features/reminders/data/reminder_audit_log.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';

/// The immediate "New alarm for you" alert (item 14, then F2/F3 2026-09-26):
/// since F3 it is an ordinary activity notification with the phone's normal
/// tone — only the due-time alarm rings. The Emergency channel is retired.

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

const _alarmCreated = {
  'type': 'created',
  'event': 'created',
  'targetUid': 'TARGET',
  'itemId': 'item-1',
  'command': 'scheduleReminder',
  'fireAtUtc': '2030-01-01T10:00:00.000Z',
  'title': 'Meds',
  'body': 'With water',
  'pushTitle': 'New alarm for you',
  'pushBody': 'Test Planner set Meds for you',
};

List<MethodCall> _fakeAndroid() {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (call.method == 'areNotificationsEnabled') return true;
        if (call.method == 'initialize') return true;
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  return calls;
}

Map _details(MethodCall show) =>
    (show.arguments as Map)['platformSpecifics'] as Map;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('channel choice', () {
    test(
      'every push, the alarm command included, is on an ordinary channel',
      () {
        for (final data in [
          _alarmCreated,
          {'event': 'created', 'itemId': 'i'},
          {'event': 'withdrawn', 'itemId': 'i'},
          {'event': 'outcome', 'subtype': 'done'},
          {'event': 'lapsed', 'audience': 'planner'},
          {'event': 'voiceUndelivered'},
        ]) {
          expect(
            channelIdForPush(data),
            kPlannerActivityChannelId,
            reason: '$data',
          );
        }
        expect(channelIdForPush({'event': 'inactivity'}), kNudgeChannelId);
      },
    );

    test('the activity channel plays the phone\'s normal tone', () {
      const c = plannerActivityChannel;
      expect(c.importance, Importance.high);
      expect(c.sound, isNull, reason: 'no custom tone: the phone default');
      expect(c.playSound, isTrue);
      expect(c.vibrationPattern, isNull);
      expect(c.id, isNot(LocalNotificationsReminderScheduler.channelId));
    });

    test('no app notification carries its own alarm tone any more', () {
      final hits = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where(
            (f) => f.readAsStringSync().contains('settings/system/alarm_alert'),
          )
          .map((f) => f.path)
          .toList();
      // Only the reminder channel's frozen legacy metadata; its notifications
      // are silent and AlarmSoundService owns the ring.
      expect(hits, [
        'lib/features/reminders/data/local_notifications_reminder_scheduler.dart',
      ]);
    });
  });

  group('posting', () {
    test(
      'foreground: the new-alarm alert posts on the activity channel',
      () async {
        final calls = _fakeAndroid();
        final shown =
            await ForegroundPushPresenter(
              FlutterLocalNotificationsPlugin(),
            ).show(
              title: 'New alarm for you',
              body: 'Test Planner set Meds for you',
              data: _alarmCreated,
            );
        expect(shown, isTrue);
        final details = _details(calls.singleWhere((c) => c.method == 'show'));
        expect(details['channelId'], kPlannerActivityChannelId);
        expect(details['importance'], Importance.high.value);
      },
    );

    test(
      'killed app: the alert posts on the activity channel and is tappable',
      () async {
        final calls = _fakeAndroid();
        await LocalNotificationsReminderScheduler(
          plugin: FlutterLocalNotificationsPlugin(),
          audit: const ReminderAuditLog(),
          onTapItem: (_) {},
        ).showNewAlarmAlert(
          itemId: 'item-1',
          title: 'New alarm for you',
          body: 'Test Planner set Meds for you',
          data: _alarmCreated,
        );
        final show = calls.singleWhere((c) => c.method == 'show');
        expect(_details(show)['channelId'], kPlannerActivityChannelId);
        expect(_details(show)['sound'], isNull);
        expect(
          decodePushTapPayload((show.arguments as Map)['payload'] as String),
          isNotNull,
        );
      },
    );

    test('initialize deletes both retired alert channels', () async {
      final calls = _fakeAndroid();
      await LocalNotificationsReminderScheduler(
        plugin: FlutterLocalNotificationsPlugin(),
        audit: const ReminderAuditLog(),
        onTapItem: (_) {},
      ).initialize();
      final deleted = calls
          .where((c) => c.method == 'deleteNotificationChannel')
          .map(
            (c) => c.arguments is Map
                ? (c.arguments as Map)['channelId']
                : c.arguments,
          )
          .toList();
      expect(deleted, contains('time_app_received_plans'));
      expect(deleted, contains(kRetiredEmergencyPlansChannelId));
      final created = calls
          .where((c) => c.method == 'createNotificationChannel')
          .map((c) => (c.arguments as Map)['id'])
          .toList();
      expect(created, isNot(contains(kRetiredEmergencyPlansChannelId)));
      expect(created, contains(kPlannerActivityChannelId));
    });

    test('the killed-app handler passes the push data through', () {
      final source = File(
        'lib/features/notifications/application/messaging_service.dart',
      ).readAsStringSync();
      expect(source, contains('showNewAlarmAlert('));
      expect(source, contains("'New alarm for you'"));
      expect(source, contains('data: message.data'));
    });
  });

  group('tap', () {
    Future<ProviderContainer> open(
      WidgetTester tester,
      Map<String, dynamic> data,
    ) async {
      final router = GoRouter(
        initialLocation: Routes.you,
        routes: [
          GoRoute(
            path: Routes.plan,
            builder: (_, _) => const Text('Plan'),
            routes: [
              GoRoute(
                path: 'approvals',
                builder: (_, _) => const Text('Approvals'),
              ),
            ],
          ),
          GoRoute(path: Routes.you, builder: (_, _) => const Text('You')),
        ],
      );
      final container = ProviderContainer(
        overrides: [routerProvider.overrideWithValue(router)],
      );
      addTearDown(container.dispose);
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      container.read(notificationRouterProvider).openForPushEvent(data);
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('an emergency alert opens the item in My Schedule', (
      tester,
    ) async {
      final container = await open(tester, _alarmCreated);
      expect(find.text('Plan'), findsOneWidget);
      expect(find.text('Approvals'), findsNothing);
      expect(container.read(planIntentProvider)?.itemId, 'item-1');
    });

    // F2: every new alarm opens that alarm in My Schedule.
    testWidgets('a normal new alarm opens that alarm in My Schedule', (
      tester,
    ) async {
      final container = await open(tester, {
        'event': 'created',
        'itemId': 'item-2',
      });
      expect(find.text('Plan'), findsOneWidget);
      expect(find.text('Approvals'), findsNothing);
      expect(container.read(planIntentProvider)?.itemId, 'item-2');
    });
  });
}
