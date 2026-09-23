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
}
