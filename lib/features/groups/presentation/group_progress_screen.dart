import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/section_header.dart';
import '../application/group_providers.dart';
import '../application/group_stats_providers.dart';
import '../domain/group_member_stat.dart';

/// **Group accountability + leaderboard** on one screen — they are two views of
/// the same published `memberStats` data (DECISIONS.md "Group accountability +
/// leaderboard"). The top is the shared story (a group streak + collective
/// follow-through); below it, the members ranked.
///
/// Every number here is PUBLISHED by each member's own device — a group member
/// cannot read another's items. A member who has never published simply is not
/// listed yet.
class GroupProgressScreen extends ConsumerWidget {
  const GroupProgressScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(groupMemberStatsProvider(groupId));
    final groupName = ref
        .watch(myGroupsProvider)
        .value
        ?.where((g) => g.id == groupId)
        .firstOrNull
        ?.name;

    return Scaffold(
      appBar: AppBar(title: Text(groupName ?? 'Group progress')),
      body: AsyncView<List<GroupMemberStat>>(
        value: statsAsync,
        onRetry: () => ref.invalidate(groupMemberStatsProvider(groupId)),
        isEmpty: (s) => s.isEmpty,
        emptyIcon: AppIcons.navStats,
        emptyMessage:
            'No activity yet. Progress shows up here as members complete plans.',
        builder: (context, stats) {
          // Leaderboard: follow-through first, then tasks done, then name.
          final ranked = [...stats]..sort((a, b) {
              final byFt = b.followThrough.compareTo(a.followThrough);
              if (byFt != 0) return byFt;
              final byDone = b.tasksCompleted.compareTo(a.tasksCompleted);
              if (byDone != 0) return byDone;
              return a.name.toLowerCase().compareTo(b.name.toLowerCase());
            });

          // The SHARED streak: the run every member currently has going — the
          // smallest individual streak, so the group only holds it while
          // everyone shows up. Its own "everyone must show" property is the
          // point of a shared streak, not a bug.
          final sharedStreak =
              stats.map((s) => s.currentStreak).reduce(math.min);
          final avgFollowThrough = stats.isEmpty
              ? 0.0
              : stats.map((s) => s.followThrough).reduce((a, b) => a + b) /
                  stats.length;

          return ListView(
            padding: Space.screenList,
            children: [
              _SharedHeader(
                sharedStreak: sharedStreak,
                avgFollowThrough: avgFollowThrough,
                memberCount: stats.length,
              ),
              const SizedBox(height: Space.md),
              const SectionHeader('Leaderboard'),
              for (var i = 0; i < ranked.length; i++)
                _LeaderRow(rank: i + 1, stat: ranked[i]),
            ],
          );
        },
      ),
    );
  }
}

/// The group's collective story: a shared streak and average follow-through.
class _SharedHeader extends StatelessWidget {
  const _SharedHeader({
    required this.sharedStreak,
    required this.avgFollowThrough,
    required this.memberCount,
  });

  final int sharedStreak;
  final double avgFollowThrough;
  final int memberCount;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(AppIcons.streak, color: context.colors.primary),
                const SizedBox(width: Space.sm),
                Text('Shared streak', style: context.text.titleMedium),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              sharedStreak == 0
                  ? "0 days — the group's streak needs everyone showing up."
                  : sharedStreak == 1
                      ? '1 day — everyone kept it going.'
                      : '$sharedStreak days — everyone kept it going.',
              style: context.text.bodyMedium,
            ),
            const SizedBox(height: Space.md),
            Text(
              'Group follow-through: ${avgFollowThrough.round()}% '
              'across $memberCount ${memberCount == 1 ? 'member' : 'members'}.',
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// One ranked member.
class _LeaderRow extends StatelessWidget {
  const _LeaderRow({required this.rank, required this.stat});

  final int rank;
  final GroupMemberStat stat;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Container(
          width: Sizes.avatarRow,
          height: Sizes.avatarRow,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.colors.primaryContainer,
            borderRadius: Radii.md,
          ),
          child: Text('$rank',
              style: context.text.titleMedium
                  ?.copyWith(color: context.colors.onPrimaryContainer)),
        ),
        title: Text(stat.name.isEmpty ? '—' : stat.name),
        subtitle: Text(
          '${stat.tasksCompleted} done · '
          '${stat.currentStreak} ${stat.currentStreak == 1 ? 'day' : 'days'} streak',
          style: context.text.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        trailing: Text(
          '${stat.followThrough.round()}%',
          style: context.text.titleMedium,
        ),
      ),
    );
  }
}
