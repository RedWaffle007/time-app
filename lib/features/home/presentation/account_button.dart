import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../routing/app_router.dart';
import '../../notifications/application/messaging_service.dart';

/// The account entry point that lives in every tab's AppBar: edit profile,
/// sign out, and (debug builds only) a way back into the dev menu while the new
/// shell is still being verified on-device.
///
/// Sign-out routes through [signOutWithTokenCleanup] so this device's FCM token
/// is removed BEFORE Firebase Auth signs out (the token write is owner-only).
class AccountButton extends ConsumerWidget {
  const AccountButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(AppIcons.account),
      tooltip: 'Account',
      onSelected: (value) {
        switch (value) {
          case 'profile':
            context.push(Routes.profile);
          case 'archived':
            context.push(Routes.archived);
          case 'dev':
            context.push(Routes.devMenu);
          case 'signout':
            signOutWithTokenCleanup(ref);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'profile', child: Text('Edit profile')),
        // Archived is account-level, not tab-level: it holds settled items from
        // both roles, and it lives here because it is a place you visit rarely
        // and deliberately.
        const PopupMenuItem(value: 'archived', child: Text('Archived')),
        // Debug-only escape hatch to the dev menu; stripped from release builds.
        if (kDebugMode)
          const PopupMenuItem(value: 'dev', child: Text('Dev menu (debug)')),
        const PopupMenuItem(value: 'signout', child: Text('Sign out')),
      ],
    );
  }
}
