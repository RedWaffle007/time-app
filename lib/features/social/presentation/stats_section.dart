import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/section_header.dart';
import '../application/stats_providers.dart';
import '../domain/profile_stat.dart';

/// **The stats section — one widget for every profile.**
///
/// It renders the signed-in user's own numbers and a stranger's withheld ones
/// with no branch, because `profileStatsProvider` has already resolved privacy
/// into a plain `List<ProfileStat>`. That is the point of the shape: the screen
/// asks for stats and gets stats, and the question of *who may see them* is
/// answered once, in one place, next to the rule that enforces it.
///
/// **Extending it takes no edit here.** Adding a statistic is one entry in
/// `kProfileStatDefinitions`; a tile appears. Turning a placeholder live is
/// giving that entry a `compute` function; the tile fills in. Nothing in this
/// file knows what a streak is.
///
/// The tiles are a wrapping grid rather than a fixed column count, so the same
/// section works on a narrow phone and a tablet without a breakpoint.
class StatsSection extends ConsumerWidget {
  const StatsSection({super.key, required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(profileStatsProvider(uid));

    return stats.when(
      // No spinner. This section sits below a profile header that has already
      // rendered, and a spinner mid-page reads as breakage; the tiles arrive
      // in place instead. AsyncView is for a screen's whole body, not a strip
      // inside one.
      loading: () => const SizedBox.shrink(),
      // Same: a stats failure must not put an error panel in the middle of an
      // otherwise working profile. The section simply does not appear.
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final withheld = list.every((s) => s.state == ProfileStatState.hidden);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Stats'),
            if (withheld) ...[
              Text(
                'This profile is private. Send a friend request to see their '
                'stats.',
                style: context.text.bodySmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              const SizedBox(height: Space.md),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                // How many tiles fit, at least one. Computed rather than
                // hardcoded so the grid reflows instead of clipping a label.
                final columns = (constraints.maxWidth /
                        (Sizes.statTileMinWidth + Space.sm))
                    .floor()
                    .clamp(1, 4);
                final width = (constraints.maxWidth -
                        (Space.sm * (columns - 1))) /
                    columns;
                return Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    for (final stat in list)
                      SizedBox(width: width, child: _StatTile(stat: stat)),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }
}

/// One statistic.
///
/// Flat, outlined, no fill (UI-RULES.md §5, §6.1). A tile is structure — it
/// holds a number, it is not a state the user must act on — so it gets a
/// hairline border and no shadow, exactly like a card.
class _StatTile extends StatelessWidget {
  const _StatTile({required this.stat});

  final ProfileStat stat;

  @override
  Widget build(BuildContext context) {
    final cs = context.colors;
    final muted = cs.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        borderRadius: Radii.md,
        border: Border.all(color: cs.outlineVariant, width: Sizes.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _value(context),
            style: context.text.titleLarge?.copyWith(
              // A real number reads at full strength; an em dash is absence and
              // must not compete with the numbers beside it.
              color: stat.state == ProfileStatState.ready ? cs.onSurface : muted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Space.xs),
          Text(
            stat.label,
            style: context.text.labelSmall?.copyWith(color: muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (stat.state == ProfileStatState.placeholder) ...[
            const SizedBox(height: Space.xs),
            Row(
              children: [
                Icon(AppIcons.stats, size: Sizes.badgeIcon, color: muted),
                const SizedBox(width: Space.xs),
                Expanded(
                  child: Text(
                    'Coming soon',
                    style: context.text.labelSmall?.copyWith(color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// The rendered value.
  ///
  /// An em dash for both [ProfileStatState.placeholder] and
  /// [ProfileStatState.hidden] — but they are never confusable, because a
  /// placeholder says "Coming soon" underneath and a withheld section says why
  /// above it. Two different explanations, one neutral glyph for "no number".
  String _value(BuildContext context) {
    if (stat.state != ProfileStatState.ready || stat.value == null) return '—';
    final value = stat.value!;
    switch (stat.unit) {
      case ProfileStatUnit.count:
        return '$value';
      case ProfileStatUnit.percent:
        return '$value%';
      case ProfileStatUnit.days:
        // Singular matters: "1 days" is the kind of detail that makes an app
        // feel unfinished.
        return value == 1 ? '1 day' : '$value days';
      case ProfileStatUnit.minutes:
        final total = value.round();
        final hours = total ~/ 60;
        final minutes = total % 60;
        if (hours == 0) return '${minutes}m';
        if (minutes == 0) return '${hours}h';
        return '${hours}h ${minutes}m';
    }
  }
}
