import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// A flat outlined card with an optional DealerPulse-style colour rail.
///
/// The rail is structural emphasis for a card's named metric, never a status
/// fill. Its caller supplies a categorical accent or semantic role.
class AccentCard extends StatelessWidget {
  const AccentCard({
    super.key,
    required this.accent,
    required this.child,
    this.margin = EdgeInsets.zero,
  });

  final Color accent;
  final Widget child;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    // IntrinsicHeight bounds the Row's cross axis to the content height, so the
    // stretched rail has a finite height to fill. Without it, in an
    // unbounded-height parent (a Wrap tile, a ListView) `stretch` forces the rail
    // to infinite height and the whole card throws — the empty-Stats bug.
    return Card(
      margin: margin,
      // `Card` paints a rounded border but does not clip its child. The accent
      // rail reaches the full tile height, so it must share that shape instead
      // of leaking square corners through the rounded left edge.
      child: ClipRRect(
        borderRadius: Radii.md,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: Sizes.ruleWidth,
                child: ColoredBox(color: accent),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
