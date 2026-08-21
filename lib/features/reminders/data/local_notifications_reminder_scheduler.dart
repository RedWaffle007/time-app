// Named collaborators, so the initializing formal the lint wants would leak the
// private field names into the public API — see `app_lock_controller.dart`.
// ignore_for_file: prefer_initializing_formals

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/reminder.dart';
import 'reminder_audit_log.dart';
import 'reminder_scheduler.dart';

/// The Android implementation, and the only file in the feature that knows what
/// AlarmManager is.
///
/// **Why `exactAllowWhileIdle`.** Measured, not assumed. `spikes/alarm_spike/`
/// armed four mechanisms at one instant on the Redmi (HyperOS, Android 16) and
/// recorded, after a 4h39m screen-off window with battery optimisation waived:
///
///   ALARM_CLOCK +0.55s · EXACT_IDLE +0.62s · WORKMANAGER +0.68s · INEXACT +110s
///
/// `AndroidScheduleMode.exactAllowWhileIdle` maps to `setExactAndAllowWhileIdle`
/// — the EXACT_IDLE row. `alarmClock` (`setAlarmClock`) measured marginally
/// better but plants a system-wide alarm icon in the status bar and lets any app
/// read the next-alarm time; that is a claim on the device an accountability app
/// has not earned, and 70ms does not buy it. The 110s figure is what
/// DECISIONS.md's previous plan would have shipped.
///
/// The permission behind it is SCHEDULE_EXACT_ALARM (user prompt, no Play
/// review), never USE_EXACT_ALARM — see the manifest.
class LocalNotificationsReminderScheduler implements ReminderScheduler {
  LocalNotificationsReminderScheduler({
    required FlutterLocalNotificationsPlugin plugin,
    required ReminderAuditLog audit,
    required void Function(String itemId) onTapItem,
  })  : _plugin = plugin,
        _audit = audit,
        _onTapItem = onTapItem;

  final FlutterLocalNotificationsPlugin _plugin;
  final ReminderAuditLog _audit;
  final void Function(String itemId) _onTapItem;

  /// **Created in code, not left to the plugin.** A channel auto-created by the
  /// first notification inherits whatever that notification asked for, and — the
  /// part that bites — a channel's importance, sound and vibration are frozen at
  /// creation and cannot be changed afterwards by any code. Getting it wrong
  /// once means every user of that install has a quiet reminder channel forever.
  ///
  /// Deliberately NOT `high_importance_channel`, which the FCM meta-data claims
  /// in the manifest. Reminders and someone-else's-activity pushes are different
  /// kinds of interruption and a user must be able to silence one without
  /// silencing the other; sharing a channel would take that away.
  static const channelId = 'time_app_reminders';
  static const _channel = AndroidNotificationChannel(
    channelId,
    'Reminders',
    description: 'Reminders for items on your schedule.',
    // `max` is for things that take over the screen. `high` is a heads-up
    // banner with sound, which is what a reminder is.
    importance: Importance.high,
  );

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      'Reminders',
      channelDescription: 'Reminders for items on your schedule.',
      importance: Importance.high,
      priority: Priority.high,
      // The white-on-transparent tray glyph. Without it Android falls back to
      // the launcher icon and, because the small icon is rendered as an alpha
      // silhouette, draws a featureless blob.
      icon: 'ic_notification',
      // Lets the OS treat it as a reminder for DND/notification grouping.
      category: AndroidNotificationCategory.reminder,
    ),
  );

  @override
  Future<void> initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        // The icon named here is the DEFAULT for notifications that do not
        // specify their own; ours does, but a wrong value here breaks any
        // future one that does not.
        android: AndroidInitializationSettings('ic_notification'),
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
  }

  void _onResponse(NotificationResponse response) {
    final itemId = response.payload;
    if (itemId == null || itemId.isEmpty) return;
    _audit.note(event: 'TAPPED', itemId: itemId, id: response.id);
    _onTapItem(itemId);
  }

  @override
  Future<bool> schedule(ReminderRequest request, int notificationId) async {
    // `zonedSchedule` throws on a non-future date, and the reconciler's `now` is
    // read before these awaits — so a reminder due in the next few hundred
    // milliseconds can go stale in flight. Drop it rather than throw: the moment
    // has passed, and the item is still sitting in My Schedule where the user
    // will see it.
    final now = DateTime.now().toUtc();
    if (!request.fireAtUtc.isAfter(now)) {
      _audit.note(
        event: 'SKIPPED_PAST',
        itemId: request.itemId,
        id: notificationId,
        fireAtUtc: request.fireAtUtc,
      );
      return false;
    }

    try {
      await _plugin.zonedSchedule(
        id: notificationId,
        title: request.title,
        body: request.body,
        // The item's stored instant is the source of truth (v1 timezone handling
        // is a pure snapshot — DECISIONS.md 2026-07-22), so this schedules an
        // ABSOLUTE moment and hands the OS UTC rather than re-deriving a wall
        // time. Re-deriving would let the reminder drift away from the instant
        // the target actually approved.
        scheduledDate: tz.TZDateTime.from(request.fireAtUtc, tz.UTC),
        notificationDetails: _details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        // The whole deep link, and deliberately just the id: a payload is a
        // string the OS keeps for hours, so it holds a key to look up, never a
        // copy of anything.
        payload: request.itemId,
      );
    } catch (e, st) {
      // A refusal here is normal on Android 14+ (exact-alarm permission), and it
      // must not take down the item stream that triggered it. Recorded in both
      // the audit CSV and Crashlytics, because a reminder that was never armed
      // is invisible by definition.
      _audit.note(
        event: 'ARM_FAILED',
        itemId: request.itemId,
        id: notificationId,
        fireAtUtc: request.fireAtUtc,
        note: '$e',
      );
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'Reminder scheduling failed — this reminder will never fire',
        fatal: false,
      );
      debugPrint('ReminderScheduler: schedule failed for ${request.itemId}: $e');
      return false;
    }

    _audit.note(
      event: 'ARMED',
      itemId: request.itemId,
      id: notificationId,
      fireAtUtc: request.fireAtUtc,
    );
    // The shadow alarm that measures when this actually lands. Best-effort and
    // deliberately after the real schedule: the instrument must never be able to
    // prevent the thing it measures.
    await _audit.arm(
      id: notificationId,
      itemId: request.itemId,
      fireAtUtc: request.fireAtUtc,
    );
    return true;
  }

  @override
  Future<void> cancel(int notificationId) async {
    await _plugin.cancel(id: notificationId);
    await _audit.cancel(notificationId);
    _audit.note(event: 'CANCELLED', id: notificationId);
  }

  @override
  Future<void> cancelAll() async {
    await _plugin.cancelAll();
    await _audit.cancelAll();
    _audit.note(event: 'CANCELLED_ALL');
  }
}

/// The Android permission surface. Split from the scheduler on purpose — see
/// [ReminderPermissions].
class LocalNotificationsReminderPermissions implements ReminderPermissions {
  LocalNotificationsReminderPermissions(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<ReminderPermissionState> read() async {
    final android = _android;
    if (android == null) {
      // Not Android. Part 1 is Android-only by scope; reporting "not ready"
      // rather than "ready" keeps a future iOS build from silently believing it
      // has permissions it never asked for.
      return const ReminderPermissionState(
        notificationsEnabled: false,
        exactAlarmsAllowed: false,
      );
    }
    return ReminderPermissionState(
      notificationsEnabled: await android.areNotificationsEnabled() ?? false,
      exactAlarmsAllowed: await android.canScheduleExactNotifications() ?? false,
    );
  }

  @override
  Future<bool> requestNotifications() async =>
      await _android?.requestNotificationsPermission() ?? false;

  @override
  Future<void> requestExactAlarms() async {
    await _android?.requestExactAlarmsPermission();
  }

  @override
  Future<void> openSystemSettings() async {
    await _android?.openAppNotificationSettings();
  }
}
