import 'package:flutter/material.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/dataviz_tokens.dart';
import '../../../core/widgets/accent_card.dart';
import '../../../core/widgets/section_header.dart';

/// **The Stats pillar — a placeholder shell (redesign slice S5).**
///
/// The five-pillar bar cutover needs a Stats destination, but the real
/// dashboard (S2) and its stat computations are **ungreenlit** and out of this
/// slice. So this ships the §6.14 shell *honestly empty*: flat outlined tiles
/// that show an em dash and "Coming soon", never a faked zero. When the
/// computations are greenlit as their own slice, they replace the placeholder
/// list here (or move to a `kProfileStatDefinitions`-style registry) — this file
/// is the seam, not the feature.
///
/// Deliberately NOT the social-profile stats on `/u/:uid` (`StatsSection`):
/// those are another person's published numbers behind a privacy gate; this is
/// the signed-in user's own personal dashboard.
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  // The tiles the dashboard will eventually hold. Labels only — no `compute`,
  // so every one renders as a placeholder. This list is the single thing the
  // greenlit computations slice edits.
  static const _placeholderLabels = <String>[
    'Follow-through',
    'Rejection rate',
    'Time tracked',
    'Current streak',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stats')),
      body: ListView(
        padding: Space.screenList,
        children: [
          const SectionHeader('Your numbers'),
          Text(
            'A personal dashboard is coming here — follow-through, time tracked '
            'and more. Nothing to show yet.',
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Space.md),
          LayoutBuilder(
            builder: (context, constraints) {
              // Reflow like the §6.9 grid — computed columns, never a hardcoded
              // count, so it fits a narrow phone and a tablet without a
              // breakpoint.
              final columns =
                  (constraints.maxWidth / (Sizes.statTileMinWidth + Space.sm))
                      .floor()
                      .clamp(1, 4);
              final width =
                  (constraints.maxWidth - (Space.sm * (columns - 1))) / columns;
              return Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: [
                  for (final label in _placeholderLabels)
                    SizedBox(
                      width: width,
                      child: _PlaceholderStatTile(label: label),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// One placeholder tile — flat, outlined, no fill (UI-RULES.md §6.1/§6.9). An em
/// dash for the value (absence, muted) and a "Coming soon" caption, mirroring the
/// social `_StatTile` placeholder so the two dashboards read as one system.
class _PlaceholderStatTile extends StatelessWidget {
  const _PlaceholderStatTile({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = context.colors;
    final muted = cs.onSurfaceVariant;

    final accent = cs.categoricalAccentFor(label);
    return AccentCard(
      accent: accent,
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('—', style: context.text.titleLarge?.copyWith(color: muted)),
            const SizedBox(height: Space.xs),
            Text(
              label,
              style: context.text.labelSmall?.copyWith(color: muted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
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
        ),
      ),
    );
  }
}
