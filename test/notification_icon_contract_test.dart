import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every Android notification path uses the Checkmate small icon', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final scheduler = File(
      'lib/features/reminders/data/local_notifications_reminder_scheduler.dart',
    ).readAsStringSync();
    final alarmService = File(
      'android/app/src/main/kotlin/com/timeapp/time_app/reminders/'
      'AlarmSoundService.kt',
    ).readAsStringSync();

    expect(
      manifest,
      contains('android:resource="@drawable/ic_notification"'),
      reason: 'background FCM notifications need the branded default icon',
    );
    expect(
      scheduler,
      contains("AndroidInitializationSettings('ic_notification')"),
      reason: 'local notifications need the branded default icon',
    );
    expect(
      scheduler,
      contains("icon: 'ic_notification'"),
      reason: 'local notification details must select the branded icon',
    );
    expect(
      alarmService,
      contains('.setSmallIcon(R.drawable.ic_notification)'),
      reason: 'the native ringing notification must use the same icon',
    );
    expect(
      alarmService,
      isNot(contains('.setSmallIcon(applicationInfo.icon)')),
      reason: 'a full-colour launcher bitmap becomes a generic white blob',
    );
  });

  test(
    'the small-icon resource is the Checkmate mark, not a generic clock',
    () {
      final icon = File(
        'android/app/src/main/res/drawable/ic_notification.xml',
      ).readAsStringSync();

      expect(icon, contains('The open C'));
      expect(icon, contains('The check'));
      expect(icon, isNot(contains('Clock face')));
      expect(icon, isNot(contains('Hour and minute hands')));
    },
  );
}
