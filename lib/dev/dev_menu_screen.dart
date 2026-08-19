import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/notifications/application/messaging_service.dart';
import '../routing/app_router.dart';
import '../core/theme/app_icons.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/app_tokens.dart';

/// ⚠️ DEV-ONLY SCAFFOLDING — NOT FOR PRODUCTION ⚠️
///
/// This screen is a temporary launcher that links to every placeholder screen
/// so the skeleton can be navigated on-device during early development. The
/// real app will start at the auth flow, NOT here.
///
/// REMOVE THIS SCREEN (and its route + initialLocation in app_router.dart)
/// before any real/release build. The sign-out here is real functionality that
/// belongs on a proper settings/profile screen later.
class DevMenuScreen extends ConsumerWidget {
  const DevMenuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Each entry: label, route, and whether that route lives INSIDE the tab
    // shell — which decides `go` vs `push`, and is not cosmetic.
    //
    // This screen is itself a root-level page pushed over the shell. Pushing a
    // shell location from here makes go_router CLONE the shell rather than
    // reuse the one already on screen: `RouteMatchList`'s
    // `_createNewMatchUntilIncompatible` only reuses the existing shell when
    // the top of the current stack is that same shell route, and the top here
    // is `/dev`. It falls through to
    // `_cloneBranchAndInsertImperativeMatch`, leaving two matches for one
    // StatefulShellRoute — and because the branch navigators are GlobalKeys,
    // that is a duplicate-GlobalKey crash, not a cosmetic second nav bar.
    //
    // So in-shell destinations use `go`: it rewrites the location, so exactly
    // one shell exists, the nav bar is there and Back works inside the branch.
    // The trade is that `go` drops this menu from the stack — Back returns to
    // the tab, not here. Only genuinely root-level routes can still be pushed.
    //
    // The alternative — registering these screens a second time as dev-only
    // root-level aliases so `push` works — is exactly the duplicate
    // registration D2 removed. Debug-only does not make it not a second
    // registration.
    final destinations = <(String label, String route, bool inShell)>[
      ('Edit Profile', Routes.profile, false),
      ('Groups & Invite', Routes.groups, true),
      ('Schedule Builder (planner)', Routes.scheduleBuilder, true),
      ('Activity (planner)', Routes.plannerActivity, true),
      ('Pending Approvals (target)', Routes.approvals, true),
      ('My Schedule / Outcomes (target)', Routes.outcome, true),
      // Root-level, so it is pushed and Back returns here. The chatbot shares
      // nothing with the delegation features but the theme and the router.
      ('Language practice (chatbot)', Routes.chatbot, false),
      ('Offline model setup (chatbot)', Routes.chatbotModel, false),
      // The HTTP service address. Off the chat's own menu since the engine went
      // on-device — nothing reads it until `chatbotServiceProvider` is pointed
      // back at HTTP — but kept reachable here for exactly that comparison.
      ('Chatbot service address (HTTP only)', Routes.chatbotSettings, false),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('DEV MENU — scaffolding only'),
        // Line work, not a fill: an orange FILL means state (UI-RULES.md §2.7)
        // and this banner is decoration. Orange text plus the rule below says
        // "dev scaffolding" without spending the signal a Pending chip relies
        // on. This screen is stripped from release builds anyway, but a rule
        // with an exception for dev is a rule with a door in it.
        foregroundColor: context.attention,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(Sizes.ruleWidth),
          child: Container(
            height: Sizes.ruleWidth,
            color: context.attention,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(AppIcons.signOut),
            onPressed: () => signOutWithTokenCleanup(ref),
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Text(
              'Dev-only launcher. Not part of a real build.\n'
              'Tap a screen to navigate the skeleton.',
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
          for (final (label, route, inShell) in destinations)
            ListTile(
              title: Text(label),
              trailing: const Icon(AppIcons.openRow),
              onTap: () => inShell ? context.go(route) : context.push(route),
            ),
        ],
      ),
    );
  }
}
