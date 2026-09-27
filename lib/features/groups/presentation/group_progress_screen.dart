import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/section_header.dart';
import '../../social/domain/profile_stat.dart';
import '../application/group_board.dart';
import '../application/group_providers.dart';
import '../application/group_stats_providers.dart';
import '../domain/group_member_stat.dart';

/// **Group progress** (item 24d, DECISIONS.md "24d — group progress"): how the
/// group is doing on the plans made IN this group, and a board of its current
/// members.
///
/// Every number is PUBLISHED by each member's own device (a member cannot read
/// another's items) and counts only this group's plans. Only current members
/// appear; members with fewer than five answered group plans are listed, not
/// ranked.
class GroupProgressScreen extends ConsumerWidget {
  const GroupProgressScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(groupMemberStatsProvider(groupId));
    final group = ref
        .watch(myGroupsProvider)
        .value
        ?.where((g) => g.id == groupId)
        .firstOrNull;

    final boardAsync = statsAsync.whenData(
      (rows) => buildGroupBoard(rows, group?.memberUids ?? const []),
    );

    return Scaffold(
      appBar: AppBar(title: Text(group?.name ?? 'Group progress')),
      body: AsyncView<GroupBoard>(
        value: boardAsync,
        onRetry: () => ref.invalidate(groupMemberStatsProvider(groupId)),
        isEmpty: (b) => b.isEmpty || b.hasNoAnswers,
        emptyIcon: AppIcons.navStats,
        emptyMessage:
            'No group plans answered yet. Progress shows here once members '
            'answer plans made in this group.',
        builder: (context, board) => ListView(
          padding: Space.screenList,
          children: [
            _GroupHeader(board: board),
            const SizedBox(height: Space.md),
            if (board.ranked.isNotEmpty) ...[
              const SectionHeader('Leaderboard'),
              for (var i = 0; i < board.ranked.length; i++)
                _MemberRow(rank: i + 1, stat: board.ranked[i]),
            ],
            if (board.unranked.isNotEmpty) ...[
              const SizedBox(height: Space.md),
              const SectionHeader('Getting started'),
              for (final stat in board.unranked) _MemberRow(stat: stat),
            ],
          ],
        ),
      ),
    );
  }
}

/// The group's shared story: who has a streak going, and pooled
/// follow-through on this group's plans.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.board});

  final GroupBoard board;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.onSurfaceVariant;
    final kept = formatCount(context, board.keptStreak);
    final total = formatCount(context, board.memberCount);
    final followThrough = board.followThrough;

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
                Text('Streaks', style: context.text.titleMedium),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              '$kept of $total kept their streak going.',
              style: context.text.bodyMedium,
            ),
            const SizedBox(height: Space.md),
            Text(
              followThrough == null
                  ? 'Group follow-through shows after '
                        '${formatCount(context, kMinStatSample)} answered '
                        'group plans.'
                  : 'Group follow-through: '
                        '${formatPercent(context, followThrough)} on plans '
                        'made in this group.',
              style: context.text.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// One member: ranked (with a position and a percentage) or getting started.
class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.stat, this.rank});

  final GroupMemberStat stat;

  /// Null for a member below the sample — listed, never ranked.
  final int? rank;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.onSurfaceVariant;
    final streak = formatCount(context, stat.currentStreak);
    final followThrough = stat.followThrough;

    return Card(
      child: ListTile(
        leading: rank == null
            ? null
            : Container(
                width: Sizes.avatarRow,
                height: Sizes.avatarRow,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: context.colors.primaryContainer,
                  borderRadius: Radii.md,
                ),
                child: Text(
                  formatCount(context, rank!),
                  style: context.text.titleMedium?.copyWith(
                    color: context.colors.onPrimaryContainer,
                  ),
                ),
              ),
        title: Text(stat.name.isEmpty ? 'Member' : stat.name),
        subtitle: Text(
          '${formatCount(context, stat.tasksCompleted)} done · '
          '$streak ${stat.currentStreak == 1 ? 'day' : 'days'} streak',
          style: context.text.bodySmall?.copyWith(color: muted),
        ),
        trailing: followThrough == null
            ? Text(
                'Needs ${formatCount(context, kMinStatSample)} answered',
                style: context.text.labelSmall?.copyWith(color: muted),
              )
            : Text(
                formatPercent(context, followThrough),
                style: context.text.titleMedium,
              ),
      ),
    );
  }
}
