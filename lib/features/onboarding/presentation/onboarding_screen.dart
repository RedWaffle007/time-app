import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/oem_profile.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../reminders/application/reminder_providers.dart';
import '../../reminders/data/reminder_scheduler.dart';
import '../application/onboarding_plan.dart';
import '../application/onboarding_providers.dart';
import '../domain/onboarding_step.dart';

/// **The first-run permission flow** — the deliberate, explained ask for every
/// permission a reminder depends on, in one place, most-consequential first.
///
/// It preserves the doctrine the reminder layer was built around: **no raw OS
/// prompt is ever fired before the user has read why.** Each step here shows its
/// reason ON SCREEN before its button touches an OS surface, so the
/// launch-time-surprise failure that the primer was created to end does not come
/// back in through onboarding. (DECISIONS.md → "Permissions onboarding".)
///
/// It is driven off the LIVE [ReminderPermissionState], not a stored cursor,
/// which is what makes it **resumable and self-skipping**: a granted step renders
/// as done, a permission granted in Settings and returned-from drops out on the
/// next resume (the app re-reads state on resume), and an all-granted stock
/// device shows nothing to do. The existing primer card stays as the repair path
/// for the three delivery permissions after onboarding is done.
///
/// Used two ways with one widget:
///   * the gate (`HomeGate`) renders it inline until [markOnboardingCompleted]
///     flips the flag it watches — [onFinished] is null there;
///   * the account menu pushes it as a route — [onFinished] pops.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.onFinished});

  /// Called after the completion flag is written. Null in gate mode (the gate
  /// swaps itself out); a pop in route mode.
  final VoidCallback? onFinished;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  bool _busy = false;

  Future<void> _finish() async {
    await markOnboardingCompleted(ref);
    if (!mounted) return;
    widget.onFinished?.call();
  }

  /// Runs one step's ask. Guards against re-entrancy while a system surface is
  /// up, and re-reads the OS afterwards so the checklist reflects reality rather
  /// than an assumption about what the user did in Settings.
  Future<void> _run(OnboardingStep step, OemProfile oem) async {
    if (_busy) return;
    setState(() => _busy = true);
    final permissions = ref.read(reminderPermissionsProvider);
    try {
      switch (step) {
        case OnboardingStep.notifications:
          final granted = await permissions.requestNotifications();
          if (!granted && mounted) {
            await _explainBlocked();
          }
        case OnboardingStep.exactAlarms:
          await permissions.requestExactAlarms();
        case OnboardingStep.fullScreenIntent:
          await permissions.requestFullScreenIntent();
        case OnboardingStep.battery:
          final launched = await permissions.requestBatteryExemption();
          if (!launched && mounted) {
            _snack("Couldn't open battery settings on this device.");
          }
        case OnboardingStep.autostart:
          final launched = await permissions.openAutostartSettings();
          if (!launched && mounted) {
            await _showAutostartGuide(oem);
          }
      }
    } finally {
      // The OS is the authority — re-read rather than assume the tap worked.
      ref.invalidate(reminderPermissionStateProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  /// After a denied notifications prompt: Android will not ask again in-app, so
  /// the only route left is Settings and the user has to be told.
  Future<void> _explainBlocked() async {
    final toSettings = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Notifications are blocked'),
        content: const Text(
          "Android won't ask again from inside the app. You can turn "
          'notifications on for time-app in system settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (toSettings == true) {
      await ref.read(reminderPermissionsProvider).openSystemSettings();
    }
  }

  /// The guided fallback for autostart — shown when no deep-link resolves on this
  /// OEM (or the resolved screen refused to launch). This is the dontkillmyapp
  /// playbook: we cannot open the screen, so we tell the user exactly where it is.
  Future<void> _showAutostartGuide(OemProfile oem) async {
    final steps = _autostartSteps(oem);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Allow ${oem.displayName} to keep time-app running'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "We couldn't open the screen directly on this phone. Here's where "
              'to find it:',
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Space.md),
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Text('•  $s', style: context.text.bodyMedium),
              ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final stateAsync = ref.watch(reminderPermissionStateProvider);
    final oem = ref.watch(oemProfileProvider).value ??
        oemProfileFor(''); // copy-only fallback while manufacturer loads

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reminders & permissions'),
      ),
      body: AsyncView<ReminderPermissionState>(
        value: stateAsync,
        onRetry: () => ref.invalidate(reminderPermissionStateProvider),
        builder: (context, state) {
          final steps = _applicableSteps(state, oem);
          return ListView(
            padding: Space.screenFormSafe(context),
            children: [
              Text(
                'For reminders to reach you, this phone needs a few '
                'permissions. Grant what you can — you can change these later.',
                style: context.text.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              const SizedBox(height: Space.lg),
              for (final step in steps)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.md),
                  child: _StepCard(
                    view: _viewFor(step, state, oem),
                    busy: _busy,
                    onAction: () => _run(step, oem),
                  ),
                ),
              const SizedBox(height: Space.sm),
              FilledButton(
                onPressed: _busy ? null : _finish,
                child: Text(
                  remainingSteps(state).isEmpty ? 'Done' : 'Continue to the app',
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---- step selection + copy ----

  /// Every step that APPLIES on this device — granted ones included, so the flow
  /// doubles as a review screen. Autostart appears only when the OEM needs it.
  List<OnboardingStep> _applicableSteps(
    ReminderPermissionState state,
    OemProfile oem,
  ) =>
      [
        OnboardingStep.notifications,
        OnboardingStep.exactAlarms,
        OnboardingStep.fullScreenIntent,
        OnboardingStep.battery,
        if (state.autostartLikelyNeeded) OnboardingStep.autostart,
      ];

  _StepView _viewFor(
    OnboardingStep step,
    ReminderPermissionState state,
    OemProfile oem,
  ) {
    switch (step) {
      case OnboardingStep.notifications:
        return _StepView(
          icon: AppIcons.reminders,
          title: 'Show reminders',
          why: 'Lets the app show a notification when an item comes due. '
              'It never leaves your device.',
          action: 'Allow notifications',
          granted: state.notificationsEnabled,
        );
      case OnboardingStep.exactAlarms:
        return _StepView(
          icon: AppIcons.exactTiming,
          title: 'Remind me on time',
          why: 'Without this, reminders can arrive late — sometimes hours late '
              'overnight. Opens Android settings.',
          action: 'Fix timing',
          granted: state.exactAlarmsAllowed,
        );
      case OnboardingStep.fullScreenIntent:
        return _StepView(
          icon: AppIcons.ringOverApps,
          title: 'Ring over other apps',
          why: 'Lets a reminder ring over other apps and on the lock screen, '
              'like a real alarm. Opens Android settings.',
          action: 'Allow',
          granted: state.fullScreenIntentAllowed,
        );
      case OnboardingStep.battery:
        return _StepView(
          icon: AppIcons.battery,
          title: 'Keep working in the background',
          why: 'Battery optimisation can stop reminders from firing while your '
              'phone is idle. Exempting time-app prevents that.',
          action: 'Allow',
          granted: state.batteryUnrestricted,
        );
      case OnboardingStep.autostart:
        return _StepView(
          icon: AppIcons.autostart,
          title: 'Let ${oem.displayName} keep time-app running',
          why: '${oem.displayName} phones can close background apps and stop '
              'their reminders. Autostart keeps them reliable. This one '
              "can't be checked automatically, so it always shows here.",
          action: 'Open settings',
          // Autostart can never be read back, so it is never "done".
          granted: false,
        );
    }
  }

  /// Per-OEM manual instructions for the guided fallback. Kept deliberately
  /// generic — exact menu names drift between skin versions, so these describe
  /// the path rather than promise a label.
  List<String> _autostartSteps(OemProfile oem) {
    switch (oem.family) {
      case OemFamily.xiaomi:
        return const [
          'Open Settings → Apps → Manage apps → time-app.',
          'Turn on "Autostart".',
          'Then Battery saver → set to "No restrictions".',
        ];
      case OemFamily.oppo:
        return const [
          'Open Settings → Apps → time-app → Battery usage.',
          'Enable "Allow background activity" and "Allow auto-launch".',
        ];
      case OemFamily.vivo:
        return const [
          'Open Settings → Battery → Background power consumption.',
          'Allow time-app to run in the background.',
          'Then i Manager → Autostart manager → enable time-app.',
        ];
      case OemFamily.oneplus:
        return const [
          'Open Settings → Apps → time-app → Battery.',
          'Set to "Don\'t optimise" and allow background activity.',
        ];
      case OemFamily.huawei:
        return const [
          'Open Settings → Apps → time-app → App launch.',
          'Turn off "Manage automatically", then allow Auto-launch and '
              'Run in background.',
        ];
      case OemFamily.samsung:
        return const [
          'Open Settings → Apps → time-app → Battery.',
          'Set to "Unrestricted".',
          'Then Settings → Battery → Background usage limits — make sure '
              'time-app is not in "Sleeping apps".',
        ];
      case OemFamily.other:
        return const [
          'Open Settings → Apps → time-app → Battery.',
          'Allow background activity / set to unrestricted.',
        ];
    }
  }
}

/// One step's rendered content — icon, title, reason, action label, grant state.
class _StepView {
  const _StepView({
    required this.icon,
    required this.title,
    required this.why,
    required this.action,
    required this.granted,
  });
  final IconData icon;
  final String title;
  final String why;
  final String action;
  final bool granted;
}

/// A single permission row. Granted → a calm confirmation. Pending → a bordered
/// card (line work, never an orange fill — §2.7) with the reason and its ask.
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.view,
    required this.busy,
    required this.onAction,
  });

  final _StepView view;
  final bool busy;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    if (view.granted) {
      return Card(
        child: Padding(
          padding: Space.cardPadding,
          child: Row(
            children: [
              Icon(AppIcons.granted,
                  color: context.colors.primary, size: Sizes.inlineIcon),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(view.title, style: context.text.titleSmall),
              ),
              Text(
                'Allowed',
                style: context.text.labelSmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      // Line work, not a fill — the attention (orange) fill means "an item is
      // waiting on you" (§2.7) and only stays trustworthy if nothing else spends
      // it. A pending permission borrows the same border the primer card uses.
      shape: RoundedRectangleBorder(
        borderRadius: Radii.md,
        side: BorderSide(color: context.attention, width: Sizes.hairline),
      ),
      child: Padding(
        padding: Space.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(view.icon,
                    color: context.attention, size: Sizes.inlineIcon),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(view.title, style: context.text.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              view.why,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Space.md),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: busy ? null : onAction,
                child: Text(view.action),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
