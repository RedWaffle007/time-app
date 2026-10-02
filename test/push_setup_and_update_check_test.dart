import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/notifications/application/messaging_service.dart';
import 'package:time_app/features/onboarding/application/onboarding_plan.dart';
import 'package:time_app/features/onboarding/domain/onboarding_step.dart';
import 'package:time_app/features/onboarding/presentation/onboarding_screen.dart';
import 'package:time_app/features/reminders/data/reminder_scheduler.dart';

/// 2026-10-02 (user report: the "Setting up notifications… Retrying…" banner
/// looped uselessly). The banner is gone; push setup retries quietly, the
/// permissions page shows its state, and that page opens again after an
/// update only when a checkable permission is missing.
void main() {
  group('quiet push-setup retries', () {
    test('back off 30 s, 2 min, 10 min, then every 30 min', () {
      expect(fcmRetryDelay(1), const Duration(seconds: 30));
      expect(fcmRetryDelay(2), const Duration(minutes: 2));
      expect(fcmRetryDelay(3), const Duration(minutes: 10));
      expect(fcmRetryDelay(4), const Duration(minutes: 30));
      expect(fcmRetryDelay(50), const Duration(minutes: 30));
      expect(fcmRetryDelay(0), const Duration(seconds: 30));
    });

    test('the permissions page states it, never asking for a retry', () {
      expect(
        friendsNotificationsStatusText(FcmRegistrationStatus.registered),
        "Friends' notifications: connected.",
      );
      expect(
        friendsNotificationsStatusText(FcmRegistrationStatus.failed),
        "Friends' notifications: not connected yet. Mind Time keeps trying on "
        'its own.',
      );
      for (final s in [
        FcmRegistrationStatus.idle,
        FcmRegistrationStatus.registering,
      ]) {
        expect(
          friendsNotificationsStatusText(s),
          "Friends' notifications: connecting…",
        );
      }
    });
  });

  group('permissions page after an update', () {
    ReminderPermissionState state({
      bool notifications = true,
      bool exact = true,
      bool fullScreen = true,
      bool battery = true,
      bool autostart = false,
    }) => ReminderPermissionState(
      notificationsEnabled: notifications,
      exactAlarmsAllowed: exact,
      fullScreenIntentAllowed: fullScreen,
      batteryUnrestricted: battery,
      autostartLikelyNeeded: autostart,
    );

    test('everything granted: skipped', () {
      expect(stepsMissingAfterUpdate(state()), isEmpty);
    });

    test('a Xiaomi with everything granted is skipped too (autostart '
        'cannot be checked, so it never forces the page)', () {
      expect(stepsMissingAfterUpdate(state(autostart: true)), isEmpty);
      // ...while a fresh install still asks for it.
      expect(remainingSteps(state(autostart: true)), [
        OnboardingStep.autostart,
      ]);
    });

    test('anything checkable missing opens the page', () {
      expect(stepsMissingAfterUpdate(state(notifications: false)), [
        OnboardingStep.notifications,
      ]);
      expect(stepsMissingAfterUpdate(state(battery: false, autostart: true)), [
        OnboardingStep.battery,
      ]);
      expect(stepsMissingAfterUpdate(state(exact: false, fullScreen: false)), [
        OnboardingStep.exactAlarms,
        OnboardingStep.fullScreenIntent,
      ]);
    });
  });
}
