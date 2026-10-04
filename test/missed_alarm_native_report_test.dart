import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/config/notify_config.dart';

/// 2026-09-27: the alarm's one-minute stop reports "unavailable" natively, so
/// the planner's Uh-Oh arrives at once instead of when the app next opens.
void main() {
  String read(String path) => File(path).readAsStringSync();
  const reporter =
      'android/app/src/main/kotlin/com/timeapp/time_app/reminders/'
      'MissedAlarmReporter.kt';

  test('the native reporter calls the same Worker as the app', () {
    expect(
      read(reporter),
      contains('const val NOTIFY_ENDPOINT = "$kNotifyEndpoint"'),
    );
  });

  test('the event name matches the Worker', () {
    expect(read(reporter), contains('const val EVENT = "alarmTimeout"'));
    expect(
      read('worker/src/alarm-timeout.js'),
      contains("ALARM_TIMEOUT_EVENT = 'alarmTimeout'"),
    );
  });

  test('the last ring reports before it stops', () {
    final service = read(
      'android/app/src/main/kotlin/com/timeapp/time_app/reminders/'
      'AlarmSoundService.kt',
    );
    final report = service.indexOf('MissedAlarmReporter.report(');
    final stop = service.indexOf('ring ended; \${missed.size} missed');
    expect(report, greaterThan(0));
    expect(report, lessThan(stop));
  });
}
