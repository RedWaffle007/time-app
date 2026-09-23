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
    required this.fullScreenIntentAllowed,
    this.batteryUnrestricted = true,
    this.autostartLikelyNeeded = false,
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

  /// USE_FULL_SCREEN_INTENT. False means the reminder still posts and still
  /// sounds when the screen is idle, but it is a suppressible notification — so
  /// while the user is in another app the OEM can (and on the Redmi does) mute
  /// it. True is what lets it ring over the top of whatever is foreground.
  ///
  /// On Android 14+ this is user-revocable for a non-alarm app; below 34 it is
  /// granted at install, so this reads true there.
  final bool fullScreenIntentAllowed;

  /// REQUEST_IGNORE_BATTERY_OPTIMIZATIONS — the Doze/battery exemption. False
  /// means the OS (and OEM battery layers) may defer or kill the process, which
  /// on the Redmi meant a Boost silently discarded every armed alarm. Defaults
  /// true because below Android M there is no Doze to be exempt from, and off
  /// Android the concept does not apply.
  ///
  /// **Deliberately NOT part of [isFullyReady].** That getter drives the
  /// existing primer card, whose copy only covers the three delivery
  /// permissions; battery and autostart are handled by the onboarding flow, so
  /// folding them in here would make the primer show with no branch to render.
  final bool batteryUnrestricted;

  /// Whether this device's manufacturer is one known to kill background apps
  /// with an autostart gate that has no reliable public intent (Xiaomi, Oppo,
  /// Vivo, Huawei, Samsung…). Derived from `Build.MANUFACTURER`, NOT an OS grant
  /// query — there is no API to read whether autostart is allowed, only whether
  /// this OEM has the setting at all. Onboarding uses it to decide whether to
  /// show the autostart step; false for stock Android and unknown OEMs, which is
  /// what makes an untested device skip the step gracefully.
  final bool autostartLikelyNeeded;

  bool get isFullyReady =>
      notificationsEnabled && exactAlarmsAllowed && fullScreenIntentAllowed;

  @override
  String toString() => 'ReminderPermissionState(notifications: '
      '$notificationsEnabled, exactAlarms: $exactAlarmsAllowed, '
      'fullScreenIntent: $fullScreenIntentAllowed, '
      'batteryUnrestricted: $batteryUnrestricted, '
      'autostartLikelyNeeded: $autostartLikelyNeeded)';
}

/// The permission surface, kept apart from [ReminderScheduler] so that asking
/// and scheduling are two separately fakeable concerns — the primer's tests
/// should not need a scheduler, and the reconciler's tests should not need
/// permissions.
abstract interface class ReminderPermissions {
  Future<ReminderPermissionState> read();

  /// Shows the Android 13+ POST_NOTIFICATIONS system prompt. Call this only
  /// AFTER the user has agreed to an onboarding/primer explanation — the OS
  /// prompt can be shown once per install in practice, and spending it on an
  /// unexplained launch-time surprise can leave notifications denied.
  Future<bool> requestNotifications();

  /// Sends the user to the system's exact-alarm settings page. There is no
  /// in-app prompt for this one; Android 14+ only grants it from Settings.
  Future<void> requestExactAlarms();

  /// Sends the user to the system's full-screen-intent settings page (Android
  /// 14+). Like exact alarms, there is no in-app prompt — the grant is made in
  /// Settings. A no-op below API 34, where the permission is granted at install.
  Future<void> requestFullScreenIntent();

  /// Fires the DIRECT battery-optimization dialog for this app (a one-tap
  /// yes/no), falling back to the battery-optimization list where the direct
  /// action is unavailable. Returns whether anything could be launched — false
  /// means neither surface exists, so onboarding shows a guided card. Never
  /// throws.
  Future<bool> requestBatteryExemption();

  /// Opens the OEM's autostart / background-launch screen, resolve-checked so it
  /// never blind-launches a component this device lacks. Returns whether a screen
  /// was actually opened; false means no launchable autostart Activity exists
  /// here, and onboarding falls back to the per-OEM guided card. Never throws.
  Future<bool> openAutostartSettings();

  /// Opens this app's notification settings — the only route back once the user
  /// has denied POST_NOTIFICATIONS, since the OS will not prompt again.
  Future<void> openSystemSettings();
}
