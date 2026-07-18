import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../dev/dev_menu_screen.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/presentation/complete_profile_screen.dart';

/// The signed-in landing point. Decides between:
///   - a spinner while the profile loads,
///   - the complete-profile screen if there's no (complete) profile yet,
///   - the app home (the dev menu, for now) once the profile is ready.
///
/// The router already guarantees we're signed in before reaching here.
class HomeGate extends ConsumerWidget {
  const HomeGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(profileProvider);

    return profileAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        body: Center(child: Text('Failed to load profile: $e')),
      ),
      data: (profile) {
        if (profile == null || !profile.isComplete) {
          return const CompleteProfileScreen();
        }
        // Profile ready — show the app home. DevMenuScreen is dev-only
        // scaffolding standing in until real home screens land.
        return const DevMenuScreen();
      },
    );
  }
}
