import '../../reminders/data/reminder_scheduler.dart';
import '../domain/onboarding_step.dart';

/// **The one place onboarding decides what to ask for.** Pure, so the
/// skip/degrade rules can be pinned in a test without a device — the same
/// discipline as the reminder reconciler, and for the same reason: getting this
/// wrong means a whole class of phones is either nagged for permissions it
/// already has or never asked for ones it needs, silently.
///
/// It is applied to whatever the live [ReminderPermissionState] currently says,
/// which is what makes onboarding **resumable**: leaving mid-flow and returning
/// simply recomputes against the new state, so a granted step drops out on its
/// own with no cursor to keep.
///
/// The rules, each mapping to a requirement:
///
///   * **auto-skip granted** — a step is included only while its permission
///     reads not-granted;
///   * **unsupported API skips the step** — below the API where a permission
///     exists it reads granted-at-install (`canScheduleExactNotifications`,
///     `canUseFullScreenIntent`, battery pre-M), so it never enters the list;
///   * **unknown OEM skips autostart** — [ReminderPermissionState.autostartLikelyNeeded]
///     is false for stock and unrecognised manufacturers, so the autostart step
///     only appears where there is actually a screen to send the user to.
///
/// [OnboardingStep.autostart] is the one exception to auto-skip: there is no API
/// to read whether autostart is allowed, so it is offered whenever the OEM is
/// known to need it and completion is tracked by the stored flag instead.
List<OnboardingStep> remainingSteps(ReminderPermissionState state) {
  return [
    if (!state.notificationsEnabled) OnboardingStep.notifications,
    if (!state.exactAlarmsAllowed) OnboardingStep.exactAlarms,
    if (!state.fullScreenIntentAllowed) OnboardingStep.fullScreenIntent,
    if (!state.batteryUnrestricted) OnboardingStep.battery,
    if (state.autostartLikelyNeeded) OnboardingStep.autostart,
  ];
}

/// Whether the first-run flow has anything left to do for [state].
///
/// Distinct from "every permission is granted": autostart cannot be verified, so
/// its mere applicability keeps this true until the user has been through the
/// flow and the stored completion flag takes over. Used by the gate to decide
/// whether to show onboarding at all — an all-granted stock device returns false
/// here and is never interrupted.
bool hasOnboardingWork(ReminderPermissionState state) =>
    remainingSteps(state).isNotEmpty;
