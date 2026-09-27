import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/section_header.dart';
import '../../../routing/app_router.dart';
import '../application/walkthrough_providers.dart';

/// **The complete "How this app works" guide**, reached from the account menu.
///
/// A short, plain reference (rewritten in Batch H5, 2026-09-27) for the
/// question the five-step coach tour is too short to answer. The tour is spatial
/// orientation over the nav bar; this is the full map. The two are complementary:
/// the "Replay the guided tour" button at the end re-runs the coach marks.
///
/// Deliberately a plain content screen (no state, no writes). It is the one place
/// that names every surface the app has, so when a feature ships its blurb is
/// added here — the same discipline the walkthrough copy list keeps for the bar.
class HowItWorksScreen extends ConsumerWidget {
  const HowItWorksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('How this app works')),
      body: ListView(
        padding: Space.screenFormSafe(context),
        children: [
          Text(
            "Friends set alarms on each other's phones. You answer with Done "
            'or Skip, and they find out.',
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Space.lg),

          const SectionHeader('The bottom bar'),
          const _Feature(
            icon: AppIcons.navSchedule,
            title: 'Plan',
            body:
                "Home shows what's next, Activity shows friends' answers, and "
                'Groups are your groups. Tap PLAN, bottom-left, to set an '
                'alarm.',
          ),
          const _Feature(
            icon: AppIcons.navRequest,
            title: 'Request',
            body:
                'Ask a friend to set an alarm for you at a time you pick. '
                "Friends' requests to you show here too.",
          ),
          const _Feature(
            icon: AppIcons.stats,
            title: 'Stats',
            body: 'Your streaks and how often you follow through.',
          ),
          const _Feature(
            icon: AppIcons.navYou,
            title: 'You',
            body: 'Your profile, as others see it. The gear opens Settings.',
          ),

          const SizedBox(height: Space.md),
          const SectionHeader('How it works'),
          const _Feature(
            icon: AppIcons.friends,
            title: 'Friends plan for each other',
            body:
                'Friends can set alarms for each other. To stop one, mark it '
                'Done or Skip before it rings, or unfriend.',
          ),
          const _Feature(
            icon: AppIcons.group,
            title: 'Groups',
            body:
                'Join with a code or an invite link. Any member can plan for '
                'the whole group; admins add and remove people.',
          ),
          const _Feature(
            icon: AppIcons.ringOverApps,
            title: 'Alarms',
            body:
                'They ring at the planned time, even over other apps or on '
                'the lock screen. A friend can send a voice note instead of '
                'a ringtone.',
          ),
          const _Feature(
            icon: AppIcons.done,
            title: 'Done or Skip',
            body:
                "The person who planned it is told right away. If you don't "
                "answer, it's marked missed at the end of the day.",
          ),

          const SizedBox(height: Space.md),
          const SectionHeader('Where things are'),
          const _Feature(
            icon: AppIcons.calendar,
            title: 'Calendar',
            body: 'On Home.',
          ),
          const _Feature(
            icon: AppIcons.archive,
            title: 'Archive',
            body: 'Plan menu, top right.',
          ),
          const _Feature(
            icon: AppIcons.voiceLibrary,
            title: 'Friends and Voice notes',
            body: 'On You.',
          ),
          const _Feature(
            icon: AppIcons.settings,
            title: 'Permissions, quiet hours, app lock, theme',
            body: 'In Settings.',
          ),

          const SizedBox(height: Space.lg),
          OutlinedButton.icon(
            onPressed: () {
              replayWalkthrough(ref);
              context.go(Routes.plan);
            },
            icon: const Icon(AppIcons.walkthrough),
            label: const Text('Replay the guided tour'),
          ),
        ],
      ),
    );
  }
}

/// One page/feature row: a leading icon, a title, and a one-line blurb.
class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: context.colors.onSurfaceVariant,
            size: Sizes.inlineIcon,
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleSmall),
                const SizedBox(height: Space.xs),
                Text(
                  body,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
