import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/async_view.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/complete_profile_screen.dart';
import '../../onboarding/presentation/onboarding_gate.dart';

/// The signed-in landing point. Decides between:
///   - a loading state (with a 12s timeout → Retry, via AsyncView) while the
///     profile loads — so a stuck profile read can't spin forever,
///   - the complete-profile screen if there's no (complete) profile yet,
///   - [child] — the tabbed shell — once the profile is ready.
///
/// The router already guarantees we're signed in before reaching here.
///
/// This gate is deliberately a **widget in the shell route's `builder`**, not a
/// `redirect`. The profile check is asynchronous, and `redirect` is kept
/// synchronous on purpose (see the note at `app_router.dart`) — an async check
/// there would need a loading location, a settled/unsettled flag and a redirect
/// loop guard to express what one `AsyncValue` says here for free.
class HomeGate extends ConsumerWidget {
  const HomeGate({super.key, required this.child});

  /// Shown once the profile exists and is complete.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(profileProvider);

    return Scaffold(
      body: AsyncView<UserProfile?>(
        value: profileAsync,
        onRetry: () => ref.invalidate(profileProvider),
        builder: (context, profile) {
          if (profile == null || !profile.isComplete) {
            return const CompleteProfileScreen();
          }
          // Permissions come after profile completion and before the app: a
          // first-run device grants what reminders need, once. Returning devices
          // pass straight through (see OnboardingGate).
          return OnboardingGate(child: child);
        },
      ),
    );
  }
}
