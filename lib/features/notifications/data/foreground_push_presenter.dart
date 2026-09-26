import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../reminders/domain/reminder.dart';

/// The Android channel for someone-else's-activity pushes. The Worker names the
/// same id (`ACTIVITY_CHANNEL_ID` in `worker/src/notify.js`) for background
/// delivery, so both paths land on one channel the user can silence without
/// silencing their own reminders. Never a reminder channel.
const kPlannerActivityChannelId = 'planner_activity';

/// The app's own re-engagement nudges (the six-hour inactivity prompt). Kept
/// apart from [kPlannerActivityChannelId] so muting nudges never mutes your
/// people. The Worker names it as `NUDGE_CHANNEL_ID` in `inactivity.js`.
const kNudgeChannelId = 'app_nudges';

/// The immediate alert when someone places an EMERGENCY plan for you (item 14,
/// 2026-09-26): max importance, its own tone and a distinct urgent vibration,
/// so it is unmistakable. It does NOT bypass Do Not Disturb (decided). The
/// alarm itself still rings at the due time on the reminder channel.
const kEmergencyPlansChannelId = 'time_app_emergency_plans';

/// Only the emergency "created" push carries the alarm-arming command.
bool isEmergencyPlanAlert(Map<String, dynamic> data) =>
    data['command'] == 'scheduleReminder';

/// Which channel a push belongs on, foreground and background alike.
String channelIdForPush(Map<String, dynamic> data) {
  if (isEmergencyPlanAlert(data)) return kEmergencyPlansChannelId;
  return (data['event'] ?? data['type']) == 'inactivity'
      ? kNudgeChannelId
      : kPlannerActivityChannelId;
}

const _emergencyName = 'Emergency plans';
const _emergencyDescription =
    'Rings out when someone you trust sets an emergency plan for you.';
final _emergencyVibration = Int64List.fromList([0, 300, 150, 300, 150, 700]);
const _emergencySound = UriAndroidNotificationSound(
  'content://settings/system/alarm_alert',
);

/// The one definition, shared by the foreground presenter and the killed-app
/// handler (via the reminder scheduler), so the two can never disagree.
final emergencyPlansChannel = AndroidNotificationChannel(
  kEmergencyPlansChannelId,
  _emergencyName,
  description: _emergencyDescription,
  importance: Importance.max,
  playSound: true,
  sound: _emergencySound,
  enableVibration: true,
  vibrationPattern: _emergencyVibration,
);

NotificationDetails emergencyPlanAlertDetails() => NotificationDetails(
  android: AndroidNotificationDetails(
    kEmergencyPlansChannelId,
    _emergencyName,
    channelDescription: _emergencyDescription,
    importance: Importance.max,
    priority: Priority.max,
    category: AndroidNotificationCategory.reminder,
    playSound: true,
    sound: _emergencySound,
    enableVibration: true,
    vibrationPattern: _emergencyVibration,
    icon: 'ic_notification',
  ),
);

const _kPushPayloadPrefix = 'push:';

/// Encode a push's routing data as a local-notification payload. The prefix is
/// what tells a tap apart from a reminder's payload, which is a bare item id
/// (Firestore ids never contain ':').
String encodePushTapPayload(Map<String, dynamic> data) =>
    '$_kPushPayloadPrefix${jsonEncode({for (final e in data.entries) e.key: e.value?.toString()})}';

/// The push data a tapped foreground notification carried, or null when
/// [payload] is not one (a reminder's item id, or anything malformed).
Map<String, dynamic>? decodePushTapPayload(String? payload) {
  if (payload == null || !payload.startsWith(_kPushPayloadPrefix)) return null;
  try {
    final decoded = jsonDecode(payload.substring(_kPushPayloadPrefix.length));
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Done/Skipped reach a planner who is IN the app as the in-app pop-up (the
/// durable `completionCelebrations` record, 2026-09-26), so the matching push
/// is not also posted as a system notification — one announcement, not two.
/// Every other push is still posted.
bool isAnnouncedInApp(Map<String, dynamic> data) =>
    (data['event'] ?? data['type']) == 'outcome';

/// How a push that arrives while the app is OPEN is presented. FCM draws
/// nothing in the foreground, so without this the planner — the person most
/// likely to be looking at the app — saw at most a transient snackbar.
enum ForegroundPushPresentation { none, snackbar }

/// What to do when the system notification could NOT be shown ([shown] false:
/// notifications disabled, or the plugin failed). A Done keeps only the
/// celebration then, which already announces it; anything else falls back to
/// the in-app snackbar so it is never silent.
ForegroundPushPresentation fallbackPresentation(Map<String, dynamic> data) {
  final isDone = data['event'] == 'outcome' && data['subtype'] == 'done';
  return isDone
      ? ForegroundPushPresentation.none
      : ForegroundPushPresentation.snackbar;
}

/// Shows a foreground push as a real system notification on
/// [kPlannerActivityChannelId]. Tapping it routes exactly like a tray tap.
class ForegroundPushPresenter {
  ForegroundPushPresenter(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  static const _activityName = 'Activity from your people';
  static const _activityDescription =
      'Plans, approvals and Done/Skip updates from people you plan with.';
  static const _nudgeName = 'Reminders to plan';
  static const _nudgeDescription =
      'An occasional nudge to plan something when you have not opened '
      'Checkmate for a while.';

  static final _channels = [
    const AndroidNotificationChannel(
      kPlannerActivityChannelId,
      _activityName,
      description: _activityDescription,
      importance: Importance.high,
    ),
    const AndroidNotificationChannel(
      kNudgeChannelId,
      _nudgeName,
      description: _nudgeDescription,
      importance: Importance.high,
    ),
    emergencyPlansChannel,
  ];

  static NotificationDetails _detailsFor(String channelId) {
    if (channelId == kEmergencyPlansChannelId) {
      return emergencyPlanAlertDetails();
    }
    final nudge = channelId == kNudgeChannelId;
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        nudge ? _nudgeName : _activityName,
        channelDescription: nudge ? _nudgeDescription : _activityDescription,
        importance: Importance.high,
        priority: Priority.high,
        icon: 'ic_notification',
      ),
    );
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Create the channels up front so a BACKGROUND push naming one lands there
  /// too; Android falls back to the manifest default for an unknown channel.
  Future<void> ensureChannel() async {
    try {
      for (final channel in _channels) {
        await _android?.createNotificationChannel(channel);
      }
    } catch (e) {
      debugPrint('TimeApp: activity channel create failed: $e');
    }
  }

  /// Whether a system notification was actually posted.
  Future<bool> show({
    required String? title,
    required String? body,
    required Map<String, dynamic> data,
  }) async {
    try {
      final android = _android;
      if (android == null) return false;
      if (await android.areNotificationsEnabled() != true) return false;
      final channelId = channelIdForPush(data);
      await android.createNotificationChannel(
        _channels.firstWhere((c) => c.id == channelId),
      );
      await _plugin.show(
        id: pushNotificationId(data),
        title: title,
        body: body,
        notificationDetails: _detailsFor(channelId),
        payload: encodePushTapPayload(data),
      );
      return true;
    } catch (e) {
      debugPrint('TimeApp: foreground push notification failed: $e');
      return false;
    }
  }
}

/// Deterministic per event, so a replayed push replaces its own notification
/// instead of stacking, and distinct events on one item (created, then its
/// outcome) stay separate. Prefixed so it cannot equal a reminder's id.
@visibleForTesting
int pushNotificationId(Map<String, dynamic> data) {
  final key = [
    data['event'] ?? data['type'],
    data['itemId'],
    data['subtype'],
    data['fromUid'],
    data['toUid'],
    data['kind'],
    data['planRequestId'],
  ].map((v) => v?.toString() ?? '').join('|');
  return reminderNotificationId('push:$key');
}
