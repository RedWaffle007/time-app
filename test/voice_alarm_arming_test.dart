import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:time_app/features/notifications/application/messaging_service.dart';
import 'package:time_app/features/reminders/application/reminder_policy.dart';
import 'package:time_app/features/reminders/data/local_notifications_reminder_scheduler.dart';
import 'package:time_app/features/reminders/data/reminder_audit_log.dart';
import 'package:time_app/features/reminders/domain/reminder.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// Item 32c-2 (2026-09-26): a voice-note alarm is armed WITH its note, so the
/// native side can play it at ring time — or ring the ringtone if the file is
/// not the approved one.

final _sha = 'c' * 64;
final _now = DateTime.utc(2030, 1, 1, 9);

ScheduleItem _item({String creator = 'PLANNER', bool voice = true}) =>
    ScheduleItem(
      id: 'item-1',
      targetUid: 'ME',
      createdByUid: creator,
      groupId: '',
      title: 'Wake up',
      localWallTime: '',
      timezone: 'Etc/UTC',
      scheduledInstantUtc: _now.add(const Duration(hours: 1)),
      status: ScheduleItemStatus.approved,
      voiceNote: voice
          ? VoiceNoteMeta(durationMs: 12000, sha256: _sha, sizeBytes: 9000)
          : null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  group('desired reminders', () {
    test("someone else's voice-note alarm carries the note", () {
      final request = desiredReminders(
        items: [_item()],
        uid: 'ME',
        now: _now,
      ).single;
      expect(request.voice?.sha256, _sha);
      expect(request.voice?.sizeBytes, 9000);
    });

    test('self-plans and plain alarms carry none', () {
      expect(
        desiredReminders(
          items: [_item(creator: 'ME')],
          uid: 'ME',
          now: _now,
        ).single.voice,
        isNull,
      );
      expect(
        desiredReminders(
          items: [_item(voice: false)],
          uid: 'ME',
          now: _now,
        ).single.voice,
        isNull,
      );
    });

    test(
      'the voice note is part of the fingerprint, and revision 3 re-arms all',
      () {
        final withVoice = desiredReminders(
          items: [_item()],
          uid: 'ME',
          now: _now,
        ).single;
        final plain = desiredReminders(
          items: [_item(voice: false)],
          uid: 'ME',
          now: _now,
        ).single;
        expect(withVoice.fingerprint, isNot(plain.fingerprint));
        expect(withVoice.fingerprint, contains(_sha));
        expect(reminderDeliveryRevision, 3);
        expect(plain.fingerprint, startsWith('3|'));
      },
    );
  });

  group('arming', () {
    Future<List<MethodCall>> arm(
      ReminderRequest request, {
      bool withPath = true,
    }) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      const plugin = MethodChannel('dexterous.com/flutter/local_notifications');
      const delivery = MethodChannel('time_app/alarm_delivery');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(plugin, (call) async => null);
      messenger.setMockMethodCallHandler(delivery, (call) async {
        calls.add(call);
        return 'ok';
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(plugin, null);
        messenger.setMockMethodCallHandler(delivery, null);
        debugDefaultTargetPlatformOverride = null;
      });
      await LocalNotificationsReminderScheduler(
        plugin: FlutterLocalNotificationsPlugin(),
        audit: const ReminderAuditLog(),
        onTapItem: (_) {},
        voicePathFor: withPath
            ? (id) async => '/data/voice-notes/$id.m4a'
            : null,
      ).schedule(request, 42);
      return calls;
    }

    test('the native arm receives the path, hash and size', () async {
      final request = desiredReminders(
        items: [_item()],
        uid: 'ME',
        now: _now,
      ).single;
      final args =
          (await arm(request)).singleWhere((c) => c.method == 'arm').arguments
              as Map;
      expect(args['voicePath'], '/data/voice-notes/item-1.m4a');
      expect(args['voiceSha256'], _sha);
      expect(args['voiceSizeBytes'], 9000);
      expect(args['headline'], 'Someone sent you a voice alarm');
    });

    test('a plain alarm arms exactly as before (no voice keys)', () async {
      final request = desiredReminders(
        items: [_item(voice: false)],
        uid: 'ME',
        now: _now,
      ).single;
      final args =
          (await arm(request)).singleWhere((c) => c.method == 'arm').arguments
              as Map;
      expect(args.containsKey('voicePath'), isFalse);
      expect(args.containsKey('voiceSha256'), isFalse);
    });
  });

  group('emergency push (killed app)', () {
    Map<String, dynamic> data({String? sha, String? size}) => {
      'command': 'scheduleReminder',
      'itemId': 'item-1',
      'targetUid': 'ME',
      'fireAtUtc': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String(),
      'title': 'Meds',
      'body': 'Tap to mark it done or skip.',
      'voiceSha256': ?sha,
      'voiceSizeBytes': ?size,
    };

    test('the voice note in the push arms the alarm with it', () {
      final request = reminderRequestFromPushData(
        data(sha: _sha, size: '9000'),
      )!;
      expect(request.voice?.sha256, _sha);
      expect(request.voice?.sizeBytes, 9000);
    });

    test('a malformed or absent voice note arms a plain alarm', () {
      expect(reminderRequestFromPushData(data())!.voice, isNull);
      expect(
        reminderRequestFromPushData(data(sha: 'nope', size: '9000'))!.voice,
        isNull,
      );
      expect(
        reminderRequestFromPushData(data(sha: _sha, size: 'x'))!.voice,
        isNull,
      );
      expect(
        reminderRequestFromPushData(data(sha: _sha, size: '0'))!.voice,
        isNull,
      );
    });

    test('the handler arms with the note path and fetches it at once', () {
      final source = File(
        'lib/features/notifications/application/messaging_service.dart',
      ).readAsStringSync();
      expect(source, contains('/voice-notes/\$itemId.m4a'));
      expect(source, contains('if (request.voice != null)'));
    });
  });

  testWidgets("'voice note didn't play' opens Plan activity", (tester) async {
    final router = GoRouter(
      initialLocation: Routes.you,
      routes: [
        GoRoute(path: Routes.plan, builder: (_, _) => const Text('Plan')),
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
    container.read(notificationRouterProvider).openForPushEvent({
      'event': 'voiceFallback',
      'itemId': 'item-1',
    });
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsOneWidget);
  });
}
