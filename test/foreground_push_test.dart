import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/notifications/data/foreground_push_presenter.dart';
import 'package:time_app/features/reminders/data/local_notifications_reminder_scheduler.dart';
import 'package:time_app/features/reminders/data/reminder_audit_log.dart';
import 'package:time_app/features/reminders/domain/reminder.dart';

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

/// Installs the Android plugin over a fake channel; [enabled] answers
/// `areNotificationsEnabled`. Returns the recorded calls.
List<MethodCall> _fakeAndroidPlugin({bool enabled = true}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (call.method == 'areNotificationsEnabled') return enabled;
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  return calls;
}

const _outcomeDone = {
  'type': 'outcome',
  'event': 'outcome',
  'targetUid': 'TARGET',
  'itemId': 'item-1',
  'subtype': 'done',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('push tap payload', () {
    test('round-trips push data', () {
      final payload = encodePushTapPayload(_outcomeDone);
      expect(decodePushTapPayload(payload), _outcomeDone);
    });

    test('a reminder payload (bare item id) is never read as a push', () {
      expect(decodePushTapPayload('item-1'), isNull);
      expect(decodePushTapPayload(''), isNull);
      expect(decodePushTapPayload(null), isNull);
    });

    test('malformed push payloads are rejected, not thrown', () {
      expect(decodePushTapPayload('push:{not json'), isNull);
      expect(decodePushTapPayload('push:[1,2]'), isNull);
    });
  });

  group('fallback when no system notification could be shown', () {
    test('Done relies on the celebration alone', () {
      expect(
        fallbackPresentation(_outcomeDone),
        ForegroundPushPresentation.none,
      );
    });

    test('Skipped and every other event fall back to the snackbar', () {
      for (final data in [
        {..._outcomeDone, 'subtype': 'skipped'},
        {'event': 'created', 'itemId': 'item-1'},
        {'event': 'decided', 'itemId': 'item-1', 'subtype': 'approved'},
        {'event': 'friendRequest', 'fromUid': 'A', 'toUid': 'B'},
      ]) {
        expect(
          fallbackPresentation(data),
          ForegroundPushPresentation.snackbar,
          reason: '$data',
        );
      }
    });
  });

  group('pushNotificationId', () {
    test('is stable for one event and distinct across events', () {
      expect(
        pushNotificationId(_outcomeDone),
        pushNotificationId({..._outcomeDone}),
      );
      final ids = {
        pushNotificationId(_outcomeDone),
        pushNotificationId({..._outcomeDone, 'subtype': 'skipped'}),
        pushNotificationId({'event': 'created', 'itemId': 'item-1'}),
        pushNotificationId({'event': 'decided', 'itemId': 'item-1'}),
      };
      expect(ids, hasLength(4));
    });

    test('never equals the item reminder id', () {
      expect(
        pushNotificationId(_outcomeDone),
        isNot(reminderNotificationId('item-1')),
      );
    });
  });

  group('ForegroundPushPresenter.show', () {
    test('posts on the activity channel with a routable payload', () async {
      final calls = _fakeAndroidPlugin();
      final shown = await ForegroundPushPresenter(
        FlutterLocalNotificationsPlugin(),
      ).show(title: 'Task completed', body: 'Body', data: _outcomeDone);

      expect(shown, isTrue);
      final show = calls.singleWhere((c) => c.method == 'show');
      final args = show.arguments as Map;
      expect(args['title'], 'Task completed');
      expect(args['payload'], encodePushTapPayload(_outcomeDone));
      expect(
        (args['platformSpecifics'] as Map)['channelId'],
        kPlannerActivityChannelId,
      );
    });

    test('reports false when notifications are disabled', () async {
      final calls = _fakeAndroidPlugin(enabled: false);
      final shown = await ForegroundPushPresenter(
        FlutterLocalNotificationsPlugin(),
      ).show(title: 'Task skipped', body: 'Body', data: _outcomeDone);

      expect(shown, isFalse);
      expect(calls.where((c) => c.method == 'show'), isEmpty);
    });
  });

  group('shared tap callback', () {
    test('a push tap routes as a push, a reminder tap as an item', () {
      final items = <String>[];
      final pushes = <Map<String, dynamic>>[];
      final scheduler = LocalNotificationsReminderScheduler(
        plugin: FlutterLocalNotificationsPlugin(),
        audit: const ReminderAuditLog(),
        onTapItem: items.add,
        onTapPush: pushes.add,
      );

      scheduler.onResponseForTest(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: encodePushTapPayload(_outcomeDone),
        ),
      );
      scheduler.onResponseForTest(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: 'item-2',
        ),
      );

      expect(pushes, [_outcomeDone]);
      expect(items, ['item-2'], reason: 'a push tap must never open /alarm');
    });
  });

  test('the Worker and the app name the same activity channel', () {
    final worker = File('worker/src/notify.js').readAsStringSync();
    expect(
      worker,
      contains("ACTIVITY_CHANNEL_ID = '$kPlannerActivityChannelId'"),
    );
  });

  test(
    'in the app, Done/Skipped are the pop-up, never a second notification',
    () {
      // 2026-09-26: the planner's in-app pop-up is the announcement for an
      // outcome; every other push is still posted as a system notification.
      expect(isAnnouncedInApp(_outcomeDone), isTrue);
      expect(isAnnouncedInApp({..._outcomeDone, 'subtype': 'skipped'}), isTrue);
      expect(isAnnouncedInApp({'type': 'outcome'}), isTrue, reason: 'legacy');
      for (final event in [
        'created',
        'decided',
        'withdrawn',
        'dismissed',
        'approvalReminder',
        'inactivity',
        'friendRequest',
        'groupJoinApproved',
      ]) {
        expect(isAnnouncedInApp({'event': event}), isFalse, reason: event);
      }

      final app = File('lib/app.dart').readAsStringSync();
      final start = app.indexOf('_showForegroundBanner(RemoteMessage');
      final gate = app.indexOf('isAnnouncedInApp(message.data)', start);
      final post = app.indexOf('foregroundPushPresenterProvider', start);
      expect(gate, greaterThan(start));
      expect(gate, lessThan(post), reason: 'the gate must precede posting');
    },
  );
}
