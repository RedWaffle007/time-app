import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../core/widgets/section_header.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/messaging_service.dart';
import '../../social/application/social_providers.dart';
import '../../social/presentation/avatar_image.dart';

/// **The You hub** (migration slice S3) — the account popup promoted to a real
/// screen, which resolves the audit's most overloaded surface: the junk-drawer
/// menu that mixed feature launchers, account settings and device config behind
/// one closed popup.
///
/// **A re-housing, not a rebuild.** Every row pushes exactly the route the popup
/// pushes today; the destination screens are untouched (their Hearth polish is
/// the S7 sweep). Reached for now through a TEMPORARY account-popup entry (the
/// temporary-door strategy); it becomes the fifth bottom-bar pillar at the S5
/// cutover, at which point the popup is retired.
///
/// Note (flagged in DECISIONS.md): Calendar is housed here per the S3 brief. The
/// locked IA has it as a Plan app-bar action — but the Plan shell does not exist
/// until S4, so it lives here in the meantime and relocates at S4/S5.
class YouScreen extends ConsumerWidget {
  const YouScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final pendingRequests = ref.watch(incomingRequestCountProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('You')),
      body: ListView(
        padding: Space.screenList,
        children: [
          // Profile header — avatar + name, tapping through to the edit form.
          Card(
            child: ListTile(
              leading: AvatarImage(profile: profile, size: Sizes.avatarRow),
              title: Text(profile?.name ?? '', style: context.text.titleMedium),
              subtitle: profile?.username == null
                  ? null
                  : Text('@${profile!.username}'),
              trailing: const Icon(AppIcons.openRow),
              onTap: () => context.push(Routes.profile),
            ),
          ),

          const SectionHeader('Places'),
          _YouTile(
            icon: AppIcons.friends,
            label: 'Friends',
            badgeCount: pendingRequests,
            onTap: () => context.push(Routes.friends),
          ),
          _YouTile(
            icon: AppIcons.calendar,
            label: 'Calendar',
            onTap: () => context.push(Routes.calendar),
          ),
          _YouTile(
            icon: AppIcons.languagePractice,
            label: 'Language practice',
            onTap: () => context.push(Routes.chatbot),
          ),

          const SectionHeader('Account & device'),
          _YouTile(
            icon: AppIcons.permissions,
            label: 'Reminders & permissions',
            onTap: () => context.push(Routes.permissions),
          ),
          if (kDebugMode)
            _YouTile(
              icon: AppIcons.devMenu,
              label: 'Dev menu (debug)',
              onTap: () => context.push(Routes.devMenu),
            ),
          _YouTile(
            icon: AppIcons.signOut,
            label: 'Sign out',
            showChevron: false,
            onTap: () => signOutWithTokenCleanup(ref),
          ),
        ],
      ),
    );
  }
}

/// One hub row — a flat outlined card (§6.1) with a leading icon, an optional
/// pending-count badge (the one orange the app trusts, §2.7) and a chevron.
class _YouTile extends StatelessWidget {
  const _YouTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badgeCount = 0,
    this.showChevron = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int badgeCount;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final leading = Icon(icon, color: context.colors.onSurfaceVariant);
    return Card(
      child: ListTile(
        leading: badgeCount > 0
            ? PendingCountBadge(count: badgeCount, child: leading)
            : leading,
        title: Text(label, style: context.text.titleMedium),
        trailing: showChevron ? const Icon(AppIcons.openRow) : null,
        onTap: onTap,
      ),
    );
  }
}
