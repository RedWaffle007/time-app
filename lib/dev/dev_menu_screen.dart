import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/notifications/application/messaging_service.dart';
import '../routing/app_router.dart';
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
    // Each entry: label + the route it pushes.
    final destinations = <(String, String)>[
      ('Edit Profile', Routes.profile),
      ('Groups & Invite', Routes.groups),
      ('Schedule Builder (planner)', Routes.scheduleBuilder),
      ('Activity (planner)', Routes.plannerActivity),
      ('Pending Approvals (target)', Routes.approvals),
      ('My Schedule / Outcomes (target)', Routes.outcome),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('DEV MENU — scaffolding only'),
        // The dev banner is an attention surface, not a warning — same family.
        backgroundColor: context.attentionContainer,
        foregroundColor: context.onAttentionContainer,
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
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
          for (final (label, route) in destinations)
            ListTile(
              title: Text(label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(route),
            ),
        ],
      ),
    );
  }
}
