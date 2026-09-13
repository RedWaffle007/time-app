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
    return Card(
      margin: margin,
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
    );
  }
}
