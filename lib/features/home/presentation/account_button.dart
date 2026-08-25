import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../routing/app_router.dart';
import '../../notifications/application/messaging_service.dart';
import '../../social/application/social_providers.dart';

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
    final pendingRequests = ref.watch(incomingRequestCountProvider);

    return PopupMenuButton<String>(
      icon: pendingRequests > 0
          ? PendingCountBadge(
              count: pendingRequests,
              child: const Icon(AppIcons.account),
            )
          : const Icon(AppIcons.account),
      tooltip: 'Account',
      onSelected: (value) {
        switch (value) {
          // Pushed, not `go`: /chatbot is a root-level route outside the shell,
          // so it covers the nav bar and Back returns to the tab you left.
          // Pushed for the same reason /chatbot is: a root-level route
          // outside the shell, covering the nav bar, with Back returning to
          // whichever tab launched it.
          case 'calendar':
            context.push(Routes.calendar);
          case 'chatbot':
            context.push(Routes.chatbot);
          case 'friends':
            context.push(Routes.friends);
          case 'profile':
            context.push(Routes.profile);
          case 'archived':
            context.push(Routes.archived);
          case 'permissions':
            context.push(Routes.permissions);
          case 'dev':
            context.push(Routes.devMenu);
          case 'signout':
            signOutWithTokenCleanup(ref);
        }
      },
      itemBuilder: (context) => [
        // The calendar heads the destinations block. It is a place you GO, and
        // it is deliberately here rather than in the nav bar: it merges the
        // items you are the target of with the ones you planned for others, so
        // it belongs to no single tab — the same shape, and the same answer, as
        // Archived below (DECISIONS.md → "In-app calendar").
        const PopupMenuItem(
          value: 'calendar',
          child: Text('Calendar'),
        ),
        // A destination, not an account action — hence its place above the
        // divider. Worded as the feature, not as "chatbot": the label names what
        // you go there to do.
        const PopupMenuItem(
          value: 'chatbot',
          child: Text('Language practice'),
        ),
        // Friends sits with the chatbot ABOVE the divider — both are places
        // you GO, as opposed to the account block below, which acts on your
        // account. It is deliberately not a fourth nav tab: the bar's three
        // destinations are the three stances in the delegation loop (target,
        // planner, group member) and a friend graph is none of them.
        //
        // Carries the same orange count badge the nav bar uses when requests
        // are waiting — the app's one trusted attention signal (UI-RULES.md
        // §2.7), and the only way this entry point announces itself, since the
        // menu it lives in is closed most of the time.
        PopupMenuItem(
          value: 'friends',
          child: Row(
            children: [
              const Text('Friends'),
              if (pendingRequests > 0) ...[
                const SizedBox(width: Space.sm),
                PendingCountBadge(
                  count: pendingRequests,
                  child: const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'profile', child: Text('Edit profile')),
        // Archived is account-level, not tab-level: it holds settled items from
        // both roles, and it lives here because it is a place you visit rarely
        // and deliberately.
        const PopupMenuItem(value: 'archived', child: Text('Archived')),
        // Re-run / review the permissions the reminder layer needs. An account
        // action rather than a destination — it changes how THIS device
        // behaves — so it sits below the divider with the account block.
        const PopupMenuItem(
          value: 'permissions',
          child: Text('Reminders & permissions'),
        ),
        // Debug-only escape hatch to the dev menu; stripped from release builds.
        if (kDebugMode)
          const PopupMenuItem(value: 'dev', child: Text('Dev menu (debug)')),
        const PopupMenuItem(value: 'signout', child: Text('Sign out')),
      ],
    );
  }
}
