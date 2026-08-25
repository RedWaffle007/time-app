import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../reminders/application/reminder_providers.dart';
import '../application/onboarding_plan.dart';
import '../application/onboarding_providers.dart';
import 'onboarding_screen.dart';

/// Decides, once per device, whether the first-run permission flow shows before
/// the app.
///
/// Sits INSIDE `HomeGate` (so it only ever runs for a signed-in user with a
/// complete profile) and wraps the tab shell. The order matters: auth → profile
/// → permissions → app.
///
/// **Only first-run users pay any cost.** For a device that has completed the
/// flow, [onboardingCompletedProvider] resolves true and the permission state is
/// never even read — the app shows immediately. A first-run device reads the
/// live OS state once: if there is genuine work ([hasOnboardingWork]) it shows
/// [OnboardingScreen]; if not (a stock phone that already has everything, or one
/// with no aggressive-OEM step) it records completion and passes straight
/// through, so the flow never flashes on a device that needs nothing.
class OnboardingGate extends ConsumerStatefulWidget {
  const OnboardingGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends ConsumerState<OnboardingGate> {
  bool _autoCompleteScheduled = false;

  /// Record completion for a device with nothing to ask, off the build phase.
  void _completeSilently() {
    if (_autoCompleteScheduled) return;
    _autoCompleteScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) markOnboardingCompleted(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final completed = ref.watch(onboardingCompletedProvider);

    return completed.when(
      // A prefs read; effectively instant. Fall through to the app rather than
      // gate every launch behind a spinner — the worst case is a first-run
      // device showing the app for one frame before the flow, which the state
      // branch below then corrects.
      loading: () => widget.child,
      error: (_, _) => widget.child,
      data: (done) {
        if (done) return widget.child;

        final stateAsync = ref.watch(reminderPermissionStateProvider);
        return stateAsync.when(
          loading: () => const _GateLoading(),
          // If we cannot read the OS state we cannot fairly ask — let the app
          // through; the primer card remains as the repair path.
          error: (_, _) => widget.child,
          data: (state) {
            if (!hasOnboardingWork(state)) {
              _completeSilently();
              return widget.child;
            }
            return const OnboardingScreen();
          },
        );
      },
    );
  }
}

class _GateLoading extends StatelessWidget {
  const _GateLoading();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
