import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../reminders/domain/reminder.dart';

/// The Android channel for someone-else's-activity pushes. The Worker names the
/// same id (`ACTIVITY_CHANNEL_ID` in `worker/src/notify.js`) for background
/// delivery, so both paths land on one channel the user can silence without
/// silencing their own reminders. Never a reminder channel.
const kPlannerActivityChannelId = 'planner_activity';

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

  static const _channel = AndroidNotificationChannel(
    kPlannerActivityChannelId,
    'Activity from your people',
    description:
        'Plans, approvals and Done/Skip updates from people you plan '
        'with.',
    importance: Importance.high,
  );

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      kPlannerActivityChannelId,
      'Activity from your people',
      channelDescription:
          'Plans, approvals and Done/Skip updates from people '
          'you plan with.',
      importance: Importance.high,
      priority: Priority.high,
      icon: 'ic_notification',
    ),
  );

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Create the channel up front so a BACKGROUND push naming it lands there
  /// too; Android falls back to the manifest default for an unknown channel.
  Future<void> ensureChannel() async {
    try {
      await _android?.createNotificationChannel(_channel);
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
      await android.createNotificationChannel(_channel);
      await _plugin.show(
        id: pushNotificationId(data),
        title: title,
        body: body,
        notificationDetails: _details,
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
