import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/async_view.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/complete_profile_screen.dart';
import 'home_shell.dart';

/// The signed-in landing point. Decides between:
///   - a loading state (with a 12s timeout → Retry, via AsyncView) while the
///     profile loads — so a stuck profile read can't spin forever,
///   - the complete-profile screen if there's no (complete) profile yet,
///   - the real app home (the bottom-nav [HomeShell]) once the profile is ready.
///
/// The router already guarantees we're signed in before reaching here.
class HomeGate extends ConsumerWidget {
  const HomeGate({super.key});

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
          return const HomeShell();
        },
      ),
    );
  }
}
