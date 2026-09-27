import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/dataviz_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/tab_body_inset.dart';
import '../../auth/application/auth_providers.dart';
import '../../social/domain/profile_stat.dart';
import '../../social/presentation/stats_section.dart';
import '../application/my_stats.dart';
import '../application/my_stats_providers.dart';

/// **The Stats pillar — the signed-in user's private dashboard** (item 24b,
/// UI-RULES §6.14). Everything is computed by [buildMyStats] from the user's
/// own record; nothing on this screen is published.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(myStatsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Stats')),
      body: TabBodyInset(
        child: AsyncView<MyStats>(
          value: stats,
          onRetry: () {
            ref.invalidate(myStatsProvider);
          },
          isEmpty: (s) => s.isEmpty,
          emptyIcon: AppIcons.navStats,
          emptyMessage:
              'No plans yet. Your numbers appear here once alarms start '
              'ringing.',
          builder: (context, s) => ListView(
            padding: Space.screenList,
            children: [
              _WeekHero(stats: s),
              const SizedBox(height: Space.lg),
              const SectionHeader('Showing up'),
              StatsGrid(stats: _showingUp(context, s)),
              const SizedBox(height: Space.lg),
              const SectionHeader('From your people'),
              StatsGrid(stats: _fromYourPeople(s)),
              if (s.topPlanners.isNotEmpty) ...[
                const SizedBox(height: Space.sm),
                _TopPlanners(planners: s.topPlanners),
              ],
              const SizedBox(height: Space.lg),
              const SectionHeader('Planning for others'),
              StatsGrid(stats: _planningForOthers(context, s)),
              const SizedBox(height: Space.lg),
              const SectionHeader('Last 8 weeks'),
              Text(
                'Plans done each week.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Space.md),
              WeekBars(counts: s.weeklyDone),
            ],
          ),
        ),
      ),
    );
  }
}

/// A percentage tile: ready with a value, or `insufficient` below the sample.
ProfileStat _percent(String key, String label, int? value, {String? caption}) =>
    ProfileStat(
      key: key,
      label: label,
      unit: ProfileStatUnit.percent,
      state: value == null
          ? ProfileStatState.insufficient
          : ProfileStatState.ready,
      value: value,
      caption: value == null ? null : caption,
    );

ProfileStat _count(
  String key,
  String label,
  num value,
  ProfileStatUnit unit, {
  String? caption,
}) => ProfileStat(
  key: key,
  label: label,
  unit: unit,
  state: ProfileStatState.ready,
  value: value,
  caption: caption,
);

List<ProfileStat> _showingUp(BuildContext context, MyStats s) {
  String? split() {
    final parts = [
      if (s.followThroughSetForYou case final v?)
        'Set for you ${formatPercent(context, v)}',
      if (s.followThroughSelf case final v?)
        'Self ${formatPercent(context, v)}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  return [
    _percent(
      'followThrough',
      'Follow-through',
      s.followThrough,
      caption: split(),
    ),
    _percent('answeredWhenRang', 'Answered when it rang', s.answeredWhenRang),
    _count(
      'currentStreak',
      'Current streak',
      s.streaks.current,
      ProfileStatUnit.days,
    ),
    _count('bestStreak', 'Best streak', s.streaks.best, ProfileStatUnit.days),
  ];
}

List<ProfileStat> _fromYourPeople(MyStats s) => [
  _count(
    'setForYou',
    'Alarms set for you',
    s.setForYouCount,
    ProfileStatUnit.count,
  ),
  _percent('setForYouDone', 'You completed', s.followThroughSetForYou),
];

List<ProfileStat> _planningForOthers(BuildContext context, MyStats s) => [
  _count(
    'alarmsSet',
    'Alarms you set for others',
    s.alarmsSetCount,
    ProfileStatUnit.count,
  ),
  _percent('alarmsSetDone', 'Completed by them', s.alarmsSetCompletion),
  _count(
    'requestsFulfilled',
    'Requests you fulfilled',
    s.requestsFulfilled,
    ProfileStatUnit.count,
  ),
  _count(
    'requestsAnswered',
    'Your requests answered',
    s.requestsAnswered,
    ProfileStatUnit.count,
    caption: s.requestsClosed == 0
        ? null
        : 'out of ${formatCount(context, s.requestsClosed)}',
  ),
];

/// The number-hero (UI-RULES §6.14): the last 7 days, and how that compares.
class _WeekHero extends StatelessWidget {
  const _WeekHero({required this.stats});

  final MyStats stats;

  @override
  Widget build(BuildContext context) {
    final last = stats.last7;
    final diff = last.done - stats.previous7.done;
    final muted = context.colors.onSurfaceVariant;
    final String comparison;
    if (diff > 0) {
      comparison =
          '${formatCount(context, diff)} more done than the week before.';
    } else if (diff < 0) {
      comparison =
          '${formatCount(context, -diff)} fewer done than the week before.';
    } else {
      comparison = 'Same as the week before.';
    }

    return Card(
      child: Padding(
        padding: Space.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Last 7 days',
              style: context.text.labelLarge?.copyWith(color: muted),
            ),
            const SizedBox(height: Space.xs),
            Text(
              formatCount(context, last.done),
              style: context.text.displaySmall?.copyWith(
                color: context.colors.primary,
              ),
            ),
            Text('done', style: context.text.titleMedium),
            const SizedBox(height: Space.sm),
            Text(
              '${formatCount(context, last.skipped)} skipped · '
              '${formatCount(context, last.missed)} missed',
              style: context.text.bodyMedium,
            ),
            const SizedBox(height: Space.xs),
            Text(
              comparison,
              style: context.text.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Who set the most alarms for the user — shown only to the user.
class _TopPlanners extends ConsumerWidget {
  const _TopPlanners({required this.planners});

  final List<PlannerCount> planners;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = context.colors.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: Space.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Most plans from',
              style: context.text.labelLarge?.copyWith(color: muted),
            ),
            const SizedBox(height: Space.sm),
            for (final p in planners)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        ref.watch(profileByUidProvider(p.uid)).value?.name ??
                            kProfileNameLoading,
                        style: context.text.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      formatCount(context, p.count),
                      style: context.text.titleSmall,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: Space.xs),
            Text(
              'Only you can see this.',
              style: context.text.labelSmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// The week bars (UI-RULES §6.14): eight rolling weeks of Done counts, oldest
/// first. Green fills on a track; a zero week shows only its track. The strip
/// carries one Semantics label with every number, so the chart is never the
/// only carrier of the data.
class WeekBars extends StatelessWidget {
  const WeekBars({super.key, required this.counts});

  /// Oldest first; the last entry is the current week.
  final List<int> counts;

  @override
  Widget build(BuildContext context) {
    final cs = context.colors;
    final peak = counts.fold<int>(0, math.max);
    final spoken = [
      for (var i = 0; i < counts.length; i++)
        i == counts.length - 1
            ? 'this week ${formatCount(context, counts[i])}'
            : '${formatCount(context, counts.length - 1 - i)} weeks ago '
                  '${formatCount(context, counts[i])}',
    ].join(', ');

    return Semantics(
      label: 'Plans done per week: $spoken',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < counts.length; i++) ...[
            if (i > 0) const SizedBox(width: Space.sm),
            Expanded(
              child: Column(
                children: [
                  SizedBox(
                    height: Sizes.weekBarsHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.progressTrack,
                        borderRadius: Radii.sm,
                      ),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          heightFactor: peak == 0 ? 0 : counts[i] / peak,
                          widthFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: cs.seriesPrimary,
                              borderRadius: Radii.sm,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    formatCount(context, counts[i]),
                    style: context.text.labelSmall?.copyWith(
                      color: cs.chartAxisLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
