import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:time_app/features/notifications/application/messaging_service.dart';
import 'package:time_app/features/reminders/data/local_notifications_reminder_scheduler.dart';
import 'package:time_app/features/reminders/data/reminder_audit_log.dart';
import 'package:time_app/features/reminders/domain/reminder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  test('trusted emergency push data becomes a future reminder request', () {
    final fireAt = DateTime.now().toUtc().add(const Duration(hours: 2));
    final request = reminderRequestFromPushData({
      'command': 'scheduleReminder',
      'itemId': 'item-1',
      'fireAtUtc': fireAt.toIso8601String(),
      'title': 'Take medicine',
      'body': 'With water',
    });

    expect(request, isNotNull);
    expect(request!.itemId, 'item-1');
    expect(request.fireAtUtc, fireAt);
    expect(request.title, 'Take medicine');
    expect(request.body, 'With water');
  });

  test('ordinary pushes cannot arm an alarm', () {
    expect(
      reminderRequestFromPushData({
        'event': 'created',
        'itemId': 'item-1',
        'fireAtUtc': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 2))
            .toIso8601String(),
        'title': 'Task',
        'body': '',
      }),
      isNull,
    );
  });

  test('malformed and past alarm commands are rejected', () {
    expect(
      reminderRequestFromPushData({
        'command': 'scheduleReminder',
        'itemId': '',
        'fireAtUtc': 'not-a-date',
        'title': '',
        'body': '',
      }),
      isNull,
    );
    expect(
      reminderRequestFromPushData({
        'command': 'scheduleReminder',
        'itemId': 'item-1',
        'fireAtUtc': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
        'title': 'Task',
        'body': '',
      }),
      isNull,
    );
  });

  test('exact-alarm denial falls back to an inexact idle alarm', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    const deliveryChannel = MethodChannel('time_app/alarm_delivery');
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(deliveryChannel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    final calls = <MethodCall>[];
    final deliveryCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (calls.length == 1) {
            throw PlatformException(code: 'exact_alarms_not_permitted');
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deliveryChannel, (call) async {
          deliveryCalls.add(call);
          return 'ok';
        });

    final plugin = FlutterLocalNotificationsPlugin();
    final scheduler = LocalNotificationsReminderScheduler(
      plugin: plugin,
      audit: const ReminderAuditLog(),
      onTapItem: (_) {},
    );
    final scheduled = await scheduler.schedule(
      ReminderRequest(
        itemId: 'friend-alarm',
        fireAtUtc: DateTime.now().toUtc().add(const Duration(hours: 2)),
        title: 'Friend plan',
        body: 'Do the thing',
      ),
      42,
    );

    expect(scheduled, isTrue);
    expect(calls.map((c) => c.method), ['zonedSchedule', 'zonedSchedule']);
    final first = calls[0].arguments as Map;
    final second = calls[1].arguments as Map;
    expect(first['platformSpecifics']['scheduleMode'], 'exactAllowWhileIdle');
    expect(
      second['platformSpecifics']['scheduleMode'],
      'inexactAllowWhileIdle',
    );
    expect(deliveryCalls.map((c) => c.method), ['arm']);
    expect(deliveryCalls.single.arguments, {
      'id': 42,
      'itemId': 'friend-alarm',
      'fireAtMillis': isA<int>(),
      // The native audio alarm must mirror the notification fallback mode.
      'exact': false,
    });
  });
}
