import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/reminders/data/local_notifications_reminder_scheduler.dart';

void main() {
  test('notification fallback never owns alarm repetition', () {
    const flagInsistent = 0x4;
    final details = buildAlarmNotificationDetails(
      LocalNotificationsReminderScheduler.channelId,
    );

    expect(details.playSound, isFalse);
    expect(details.silent, isTrue);
    expect(details.enableVibration, isFalse);
    expect(details.fullScreenIntent, isFalse);
    expect(
      details.additionalFlags?.contains(flagInsistent) ?? false,
      isFalse,
      reason: 'AlarmSoundService must be the only repeating tone owner',
    );
  });

  test('the alarm notification channel itself is silent (2026-09-28)', () {
    // HyperOS ignored the per-notification "silent" and played the channel's
    // sound, the phone's alarm tone, as a notification tone.
    final channel = LocalNotificationsReminderScheduler.alarmChannelForTest;
    expect(channel.id, 'time_app_reminders_silent');
    expect(channel.playSound, isFalse);
    expect(channel.sound, isNull);
    expect(channel.enableVibration, isFalse);
    expect(channel.audioAttributesUsage, isNot(AudioAttributesUsage.alarm));
  });

  test('the retired alarm-tone channel is deleted on start', () {
    final src = File(
      'lib/features/reminders/data/local_notifications_reminder_scheduler.dart',
    ).readAsStringSync();
    expect(src, contains("'time_app_reminders_alert'"));
    expect(src, contains('channelId: _retiredAlarmSoundChannelId'));
    expect(src, isNot(contains('alarm_alert')));
  });
}
