import '../domain/reminder.dart';

/// **The seam.** Everything above this line reasons about items and instants;
/// everything below it knows about Android, AlarmManager and channel ids.
///
/// Same shape and the same reason as `chatbot_service.dart`: no OS vocabulary
/// may cross it. No `AndroidScheduleMode`, no channel id, no `TZDateTime`, no
/// `PendingNotificationRequest`. That is what lets [ReminderReconciler] and
/// [ReminderService] be tested with a fake and no device, and it is what makes
/// the eventual iOS implementation a second class behind this interface rather
/// than a fork of the scheduling logic.
///
/// The methods are deliberately dumb. This interface makes no decisions: it does
/// not know what an approved item is, it does not dedupe, and it never asks
/// whether something is already scheduled. All of that is the reconciler's job,
/// because all of it is testable and none of it is.
abstract interface class ReminderScheduler {
  /// Prepares the platform: notification channel, tap callback wiring. Safe to
  /// call more than once — [ReminderService] does not track whether it ran.
  Future<void> initialize();

  /// Registers (or replaces) the OS notification for [request] under
  /// [notificationId]. Returns whether the OS actually accepted it.
  ///
  /// Replacement is by id and is the platform's own behaviour, so a re-schedule
  /// needs no cancel first.
  ///
  /// **Must not throw for an ordinary platform refusal.** A revoked exact-alarm
  /// permission is a normal state on Android 14+ — and on this Redmi it is the
  /// state after every single reinstall — not an error the item stream should
  /// die on. It reports `false` instead, which keeps the reminder OUT of the
  /// mirror so the next reconcile retries it. That is the whole recovery path
  /// for "user granted the permission after we already tried".
  Future<bool> schedule(ReminderRequest request, int notificationId);

  Future<void> cancel(int notificationId);

  /// Drops everything this app scheduled. Used on sign-out and account switch:
  /// one person's reminders must never fire on another person's session.
  Future<void> cancelAll();
}

/// What the OS will currently let us do. Read-only; the asks live in
/// [ReminderPermissions].
class ReminderPermissionState {
  const ReminderPermissionState({
    required this.notificationsEnabled,
    required this.exactAlarmsAllowed,
  });

  /// POST_NOTIFICATIONS. False means a scheduled reminder fires and posts
  /// nothing at all — silently. This is the state the primer exists to fix.
  final bool notificationsEnabled;

  /// SCHEDULE_EXACT_ALARM. False downgrades a reminder from "±0.6s" to "whenever
  /// Doze feels like it" — the spike measured that difference as 0.55s versus
  /// 110s on this device, so it is the difference between a reminder and a
  /// suggestion.
  ///
  /// On the Redmi this is revoked by **every reinstall** (spike README trap 1),
  /// so it must be re-read at runtime and never cached across a launch.
  final bool exactAlarmsAllowed;

  bool get isFullyReady => notificationsEnabled && exactAlarmsAllowed;

  @override
  String toString() => 'ReminderPermissionState(notifications: '
      '$notificationsEnabled, exactAlarms: $exactAlarmsAllowed)';
}

/// The permission surface, kept apart from [ReminderScheduler] so that asking
/// and scheduling are two separately fakeable concerns — the primer's tests
/// should not need a scheduler, and the reconciler's tests should not need
/// permissions.
abstract interface class ReminderPermissions {
  Future<ReminderPermissionState> read();

  /// Shows the Android 13+ POST_NOTIFICATIONS system prompt. Call this only
  /// AFTER the user has agreed to a primer — the OS prompt can be shown once
  /// per install in practice, and spending it on a launch-time surprise is how
  /// an app ends up permanently unable to notify anyone.
  Future<bool> requestNotifications();

  /// Sends the user to the system's exact-alarm settings page. There is no
  /// in-app prompt for this one; Android 14+ only grants it from Settings.
  Future<void> requestExactAlarms();

  /// Opens this app's notification settings — the only route back once the user
  /// has denied POST_NOTIFICATIONS, since the OS will not prompt again.
  Future<void> openSystemSettings();
}
