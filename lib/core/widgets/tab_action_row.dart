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

/// The button row at the TOP of each Plan sub-tab, in three columns that line
/// up under the three tab labels (Home · Activity · Groups), device report
/// 2026-09-28:
///
///   Home tab      CALENDAR      HISTORY       ARCHIVE
///   Activity tab  —             —             ARCHIVE
///   Groups tab    CREATE GROUP  JOIN GROUP    ARCHIVE
///
/// ARCHIVE is always under "Groups", so it never moves on a swipe. Buttons are
/// compact, bold and outlined in the brand green; a long label scales down
/// rather than overflowing its column.
class TabActionRow extends StatelessWidget {
  const TabActionRow({
    super.key,
    this.home,
    this.activity,
    required this.groups,
  });

  final TabAction? home;
  final TabAction? activity;
  final TabAction groups;

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      textStyle: context.text.labelLarge?.copyWith(fontWeight: FontWeight.bold),
      visualDensity: VisualDensity.compact,
      shape: const RoundedRectangleBorder(borderRadius: Radii.md),
      side: BorderSide(color: context.colors.primary, width: Sizes.hairline),
    );
    Widget slot(TabAction? a) => Expanded(
      child: a == null
          ? const SizedBox.shrink()
          : Center(
              child: OutlinedButton(
                key: a.key,
                style: style,
                onPressed: a.onPressed,
                child: FittedBox(fit: BoxFit.scaleDown, child: Text(a.label)),
              ),
            ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm, bottom: Space.xs),
      child: Row(children: [slot(home), slot(activity), slot(groups)]),
    );
  }
}
