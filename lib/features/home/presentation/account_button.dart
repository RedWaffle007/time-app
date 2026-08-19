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
/// **It is also the chatbot's front door** (DECISIONS.md, 2026-08-18). Language
/// practice is not an account action, so it sits ABOVE a divider, apart from the
/// account block — the menu reads as "a place you can go", then "your account".
/// It lives here rather than in the nav bar because the bar's three tabs are the
/// three stances in the delegation loop and the chatbot is not one of them; and
/// it lives here rather than only in the dev menu because that is debug-only
/// scaffolding, which left the feature with no door at all in a release build.
/// Since this widget renders in all three tab AppBars, one item reaches it from
/// anywhere.
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
          // Pushed, not `go`: /chatbot is a root-level route outside the shell,
          // so it covers the nav bar and Back returns to the tab you left.
          case 'chatbot':
            context.push(Routes.chatbot);
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
        // A destination, not an account action — hence its place above the
        // divider. Worded as the feature, not as "chatbot": the label names what
        // you go there to do.
        const PopupMenuItem(
          value: 'chatbot',
          child: Text('Language practice'),
        ),
        const PopupMenuDivider(),
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
