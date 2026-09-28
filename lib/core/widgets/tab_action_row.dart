import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// One button in a [TabActionRow].
class TabAction {
  const TabAction({required this.label, required this.onPressed, this.key});

  final String label;
  final VoidCallback onPressed;
  final Key? key;
}

/// The row of compact, bold outlined buttons at the TOP of each Plan sub-tab
/// (2026-09-28): Home = CALENDAR · HISTORY · ARCHIVE, Activity = ARCHIVE,
/// Groups = CREATE GROUP · JOIN GROUP · ARCHIVE. Same place and style on every
/// tab, so a swipe between tabs never moves them. Wraps (end-aligned) rather
/// than overflowing on a narrow phone.
class TabActionRow extends StatelessWidget {
  const TabActionRow({super.key, required this.actions});

  final List<TabAction> actions;

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      textStyle: context.text.labelLarge?.copyWith(fontWeight: FontWeight.bold),
      visualDensity: VisualDensity.compact,
      shape: const RoundedRectangleBorder(borderRadius: Radii.md),
    );
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm, bottom: Space.xs),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: Space.sm,
        runSpacing: Space.xs,
        children: [
          for (final a in actions)
            OutlinedButton(
              key: a.key,
              style: style,
              onPressed: a.onPressed,
              child: Text(a.label),
            ),
        ],
      ),
    );
  }
}
