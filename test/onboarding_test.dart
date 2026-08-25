import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/platform/oem_profile.dart';
import 'package:time_app/core/platform/system_permissions.dart';
import 'package:time_app/features/onboarding/application/onboarding_plan.dart';
import 'package:time_app/features/onboarding/domain/onboarding_step.dart';
import 'package:time_app/features/reminders/data/reminder_scheduler.dart';

/// The onboarding logic is pure — which permission to ask for, and which OEM
/// needs the autostart step — so its correctness lives here rather than on one
/// of every manufacturer's phones. The failure mode of getting either wrong is a
/// class of devices silently never delivering a reminder, so it must be testable
/// without owning the hardware.
void main() {
  // The MethodChannel seam test below invokes real channels; a binding turns a
  // missing native handler into the MissingPluginException the try/catch swallows.
  TestWidgetsFlutterBinding.ensureInitialized();

  // A state with everything granted and no aggressive OEM — the "nothing to do"
  // baseline each test perturbs one field of.
  ReminderPermissionState state({
    bool notifications = true,
    bool exact = true,
    bool fsi = true,
    bool battery = true,
    bool autostart = false,
  }) =>
      ReminderPermissionState(
        notificationsEnabled: notifications,
        exactAlarmsAllowed: exact,
        fullScreenIntentAllowed: fsi,
        batteryUnrestricted: battery,
        autostartLikelyNeeded: autostart,
      );

  group('remainingSteps — auto-skip granted', () {
    test('all granted, stock OEM → nothing to do', () {
      expect(remainingSteps(state()), isEmpty);
      expect(hasOnboardingWork(state()), isFalse);
    });

    test('a revoked permission surfaces exactly its own step', () {
      expect(remainingSteps(state(notifications: false)),
          [OnboardingStep.notifications]);
      expect(remainingSteps(state(exact: false)), [OnboardingStep.exactAlarms]);
      expect(remainingSteps(state(fsi: false)),
          [OnboardingStep.fullScreenIntent]);
      expect(remainingSteps(state(battery: false)), [OnboardingStep.battery]);
    });

    test('steps come back in consequence order, most-consequential first', () {
      final all = remainingSteps(state(
        notifications: false,
        exact: false,
        fsi: false,
        battery: false,
        autostart: true,
      ));
      expect(all, [
        OnboardingStep.notifications,
        OnboardingStep.exactAlarms,
        OnboardingStep.fullScreenIntent,
        OnboardingStep.battery,
        OnboardingStep.autostart,
      ]);
    });
  });

  group('remainingSteps — autostart is special', () {
    test('unknown/stock OEM never gets the autostart step', () {
      // autostartLikelyNeeded false is exactly the graceful-skip case.
      expect(remainingSteps(state(autostart: false)),
          isNot(contains(OnboardingStep.autostart)));
    });

    test('an aggressive OEM always keeps work to do, even fully granted', () {
      // Autostart cannot be read back, so it is offered until the stored flag
      // takes over — hasOnboardingWork stays true on such a device.
      final s = state(autostart: true);
      expect(remainingSteps(s), [OnboardingStep.autostart]);
      expect(hasOnboardingWork(s), isTrue);
    });
  });

  group('ReminderPermissionState defaults', () {
    test('battery/autostart default to the safe no-op values', () {
      // The existing three-arg constructor sites must keep compiling AND behave
      // as "no battery restriction, no autostart step" so the primer is unmoved.
      const s = ReminderPermissionState(
        notificationsEnabled: true,
        exactAlarmsAllowed: true,
        fullScreenIntentAllowed: true,
      );
      expect(s.batteryUnrestricted, isTrue);
      expect(s.autostartLikelyNeeded, isFalse);
      expect(s.isFullyReady, isTrue);
    });

    test('isFullyReady is still the delivery trio only, never battery', () {
      // Folding battery into isFullyReady would make the primer card show with
      // no branch to render it — the regression the field docs warn against.
      expect(state(battery: false).isFullyReady, isTrue);
      expect(state(notifications: false).isFullyReady, isFalse);
    });
  });

  group('oemProfileFor — OEM branch selection', () {
    test('the aggressive families are recognised and flagged', () {
      final aggressive = {
        'Xiaomi': OemFamily.xiaomi,
        'Redmi': OemFamily.xiaomi,
        'POCO': OemFamily.xiaomi,
        'OPPO': OemFamily.oppo,
        'realme': OemFamily.oppo,
        'OnePlus': OemFamily.oneplus,
        'vivo': OemFamily.vivo,
        'iQOO': OemFamily.vivo,
        'HUAWEI': OemFamily.huawei,
        'Honor': OemFamily.huawei,
        'samsung': OemFamily.samsung,
      };
      aggressive.forEach((manufacturer, family) {
        final profile = oemProfileFor(manufacturer);
        expect(profile.family, family, reason: manufacturer);
        expect(profile.autostartLikelyNeeded, isTrue, reason: manufacturer);
      });
    });

    test('matching is case-insensitive and tolerant of surrounding text', () {
      expect(oemProfileFor('  XIAOMI  ').family, OemFamily.xiaomi);
      expect(oemProfileFor('Xiaomi Communications').family, OemFamily.xiaomi);
    });

    test('stock and unknown manufacturers skip the autostart step', () {
      for (final m in ['Google', 'motorola', 'Nokia', 'Sony', 'Fairphone']) {
        final profile = oemProfileFor(m);
        expect(profile.family, OemFamily.other, reason: m);
        expect(profile.autostartLikelyNeeded, isFalse, reason: m);
      }
    });

    test('an empty manufacturer (off Android / read failure) is a safe skip', () {
      final profile = oemProfileFor('');
      expect(profile.family, OemFamily.other);
      expect(profile.autostartLikelyNeeded, isFalse);
      expect(profile.displayName, isNotEmpty); // still renders in copy
    });

    test('a stock device keeps its reported name for copy', () {
      expect(oemProfileFor('Motorola').displayName, 'Motorola');
    });
  });

  group('SystemPermissions — never throws', () {
    // With no native handler registered (a plain test host), every call must
    // degrade to its stated safe default rather than let a MissingPluginException
    // escape into the onboarding flow that drives it.
    const sys = MethodChannelSystemPermissions();

    test('battery read reports "no restriction we can see"', () async {
      expect(await sys.isBatteryUnrestricted(), isTrue);
    });

    test('the asks report "could not launch" rather than throwing', () async {
      expect(await sys.requestBatteryExemption(), isFalse);
      expect(await sys.canOpenAutostartSettings(), isFalse);
      expect(await sys.openAutostartSettings(), isFalse);
    });
  });
}
