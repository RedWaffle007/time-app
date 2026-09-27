import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/notifications/data/foreground_push_presenter.dart';

/// Batch G item 6 (2026-09-27): "{Y} was unavailable to dismiss the task…"
/// reaches the planner with a cartoon "Uh-Oh!" instead of the phone's tone.
void main() {
  test('the unavailable push has its own channel; others are unchanged', () {
    expect(
      channelIdForPush({'event': 'unavailable'}),
      kPlannerUnavailableChannelId,
    );
    expect(channelIdForPush({'event': 'dismissed'}), kPlannerActivityChannelId);
    expect(channelIdForPush({'event': 'inactivity'}), kNudgeChannelId);
  });

  test('that channel plays the bundled "Uh-Oh!"', () {
    final sound = plannerUnavailableChannel.sound;
    expect(sound, isA<RawResourceAndroidNotificationSound>());
    expect(sound!.sound, 'uh_oh');
    expect(plannerUnavailableChannel.playSound, isTrue);
    expect(plannerUnavailableChannel.importance, Importance.high);
  });

  test('the sound file ships in res/raw, and the ids match the Worker', () {
    expect(File('android/app/src/main/res/raw/uh_oh.mp3').existsSync(), isTrue);
    final worker = File('worker/src/notify.js').readAsStringSync();
    expect(
      worker,
      contains("UNAVAILABLE_CHANNEL_ID = '$kPlannerUnavailableChannelId'"),
    );
    expect(NotifyEvent.unavailable.name, 'unavailable');
  });

  // 2026-09-27: release resource shrinking deleted uh_oh.mp3 (nothing names
  // it through R.raw), so the notice arrived silent. A keep rule pins it.
  test('release builds keep the "Uh-Oh!" file', () {
    final keep = File(
      'android/app/src/main/res/raw/time_app_keep.xml',
    ).readAsStringSync();
    expect(keep, contains('tools:keep="@raw/uh_oh"'));
  });

  test('both places that create channels create it', () {
    final scheduler = File(
      'lib/features/reminders/data/local_notifications_reminder_scheduler.dart',
    ).readAsStringSync();
    expect(scheduler, contains('plannerUnavailableChannel'));
  });
}
