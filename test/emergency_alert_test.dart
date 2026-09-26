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

/// Item 14 (2026-09-26): the immediate alert for an emergency plan has its own
/// max-importance channel, and every emergency push says "Emergency".

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

const _emergencyCreated = {
  'type': 'created',
  'event': 'created',
  'targetUid': 'TARGET',
  'itemId': 'item-1',
  'command': 'scheduleReminder',
  'fireAtUtc': '2030-01-01T10:00:00.000Z',
  'title': 'Meds',
  'body': 'With water',
  'pushTitle': 'New emergency plan for you',
  'pushBody': 'Test Planner planned Meds for you',
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
    test('only the arming emergency push uses the emergency channel', () {
      expect(isEmergencyPlanAlert(_emergencyCreated), isTrue);
      expect(channelIdForPush(_emergencyCreated), kEmergencyPlansChannelId);
      for (final data in [
        {'event': 'created', 'itemId': 'i'},
        {'event': 'outcome', 'subtype': 'done'},
        {'event': 'dismissed'},
        {'event': 'lapsed', 'audience': 'planner'},
      ]) {
        expect(
          channelIdForPush(data),
          kPlannerActivityChannelId,
          reason: '$data',
        );
      }
      expect(channelIdForPush({'event': 'inactivity'}), kNudgeChannelId);
    });

    test('the emergency channel is max importance, own tone and vibration', () {
      final c = emergencyPlansChannel;
      expect(c.id, kEmergencyPlansChannelId);
      expect(c.importance, Importance.max);
      expect(c.playSound, isTrue);
      expect(c.sound, isA<UriAndroidNotificationSound>());
      expect(c.enableVibration, isTrue);
      expect(c.vibrationPattern, isNotNull);
      // It is not the reminder (alarm) channel, and not the activity one.
      expect(c.id, isNot(LocalNotificationsReminderScheduler.channelId));
      expect(c.id, isNot(kPlannerActivityChannelId));
    });
  });

  group('posting', () {
    test(
      'foreground: the emergency alert posts on the emergency channel',
      () async {
        final calls = _fakeAndroid();
        final shown =
            await ForegroundPushPresenter(
              FlutterLocalNotificationsPlugin(),
            ).show(
              title: 'New emergency plan for you',
              body: 'Test Planner planned Meds for you',
              data: _emergencyCreated,
            );
        expect(shown, isTrue);
        final details = _details(calls.singleWhere((c) => c.method == 'show'));
        expect(details['channelId'], kEmergencyPlansChannelId);
        expect(details['importance'], Importance.max.value);
      },
    );

    test(
      'killed app: the alert posts on the emergency channel and is tappable',
      () async {
        final calls = _fakeAndroid();
        await LocalNotificationsReminderScheduler(
          plugin: FlutterLocalNotificationsPlugin(),
          audit: const ReminderAuditLog(),
          onTapItem: (_) {},
        ).showEmergencyPlanAlert(
          itemId: 'item-1',
          title: 'New emergency plan for you',
          body: 'Test Planner planned Meds for you',
          data: _emergencyCreated,
        );
        final show = calls.singleWhere((c) => c.method == 'show');
        expect(_details(show)['channelId'], kEmergencyPlansChannelId);
        expect(
          decodePushTapPayload((show.arguments as Map)['payload'] as String),
          isNotNull,
        );
      },
    );

    test(
      'initialize retires the old channel and creates the emergency one',
      () async {
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
        final created = calls
            .where((c) => c.method == 'createNotificationChannel')
            .map((c) => (c.arguments as Map)['id'])
            .toList();
        expect(created, contains(kEmergencyPlansChannelId));
      },
    );

    test('the killed-app handler passes the push data through', () {
      final source = File(
        'lib/features/notifications/application/messaging_service.dart',
      ).readAsStringSync();
      expect(source, contains('showEmergencyPlanAlert('));
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
      final container = await open(tester, _emergencyCreated);
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
