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
/// A scrollable reference — one tight blurb per page and feature — for the
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
        padding: Space.screenForm,
        children: [
          Text(
            'time-app lets people you trust build your schedule and set your '
            'reminders — always with your approval. Here is every part of it.',
            style: context.text.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Space.lg),

          const SectionHeader('The three tabs'),
          const _Feature(
            icon: AppIcons.navSchedule,
            title: 'Plan · My Schedule',
            body: 'Your day, next task first. Build items for yourself or for '
                'people who let you plan for them, and set the reminders.',
          ),
          const _Feature(
            icon: AppIcons.navTrack,
            title: 'Track · Activity',
            body: 'Log time you have already spent and see where your hours go.',
          ),
          const _Feature(
            icon: AppIcons.stats,
            title: 'Stats',
            body: 'Your totals, trends and streaks at a glance.',
          ),
          const _Feature(
            icon: AppIcons.voice,
            title: 'Speak to create',
            body: 'The centre mic: tap and talk to log time or plan a reminder, '
                'hands-free. You review it before anything is saved.',
          ),

          const SizedBox(height: Space.md),
          const SectionHeader('Planning together'),
          const _Feature(
            icon: AppIcons.group,
            title: 'Groups & invites',
            body: 'Create a group and invite people with a code. Members can be '
                'given permission to plan for each other.',
          ),
          const _Feature(
            icon: AppIcons.permissions,
            title: 'Consent to be planned for',
            body: 'Nobody can plan for you until you allow it — per person, and '
                'revocable any time. A friendship alone grants nothing.',
          ),
          const _Feature(
            icon: AppIcons.approved,
            title: 'Approve or reject',
            body: 'Every item a planner creates lands pending. It only fires '
                'after you approve it; reject or withdraw removes it.',
          ),
          const _Feature(
            icon: AppIcons.emergency,
            title: 'Emergency items',
            body: 'A separate grant lets a trusted friend place an item that '
                'skips the queue and rings straight away. Off by default.',
          ),

          const SizedBox(height: Space.md),
          const SectionHeader('Reminders & alarms'),
          const _Feature(
            icon: AppIcons.reminders,
            title: 'Reminders',
            body: 'Approved items notify you when they are due — on this device, '
                'nothing leaving it.',
          ),
          const _Feature(
            icon: AppIcons.ringOverApps,
            title: 'Alarm mode',
            body: 'With the right permissions a reminder rings like a real '
                'alarm: on time, over other apps, and on the lock screen.',
          ),
          const _Feature(
            icon: AppIcons.approved,
            title: 'Accountability',
            body: 'When you mark an item done or skipped, the person who planned '
                'it is notified — that is what closes the loop.',
          ),

          const SizedBox(height: Space.md),
          const SectionHeader('More'),
          const _Feature(
            icon: AppIcons.stats,
            title: 'Group progress & leaderboard',
            body: 'A shared streak and a follow-through leaderboard across a '
                "group's members.",
          ),
          const _Feature(
            icon: AppIcons.friends,
            title: 'Friends',
            body: 'Add people, manage requests, and control who can see your '
                'profile.',
          ),
          const _Feature(
            icon: AppIcons.calendar,
            title: 'Calendar',
            body: 'A month, week and day view over everything scheduled, in each '
                "item's own timezone.",
          ),
          const _Feature(
            icon: AppIcons.languagePractice,
            title: 'Language practice',
            body: 'An optional offline German chatbot — a separate extra, not '
                'part of the planning loop.',
          ),
          const _Feature(
            icon: AppIcons.permissions,
            title: 'Reminders & permissions',
            body: 'Review and fix the permissions reliable reminders need, any '
                'time.',
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
          Icon(icon,
              color: context.colors.onSurfaceVariant, size: Sizes.inlineIcon),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleSmall),
                const SizedBox(height: Space.xs),
                Text(
                  body,
                  style: context.text.bodySmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
