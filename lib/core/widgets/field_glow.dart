import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// The static halo behind the builder's primary inputs (UI-RULES §6.2b).
/// Decorative only: the child keeps its own border, label and error text.
class FieldGlow extends StatelessWidget {
  const FieldGlow({
    super.key,
    required this.child,
    this.error = false,
    this.borderRadius = Radii.sm,
  });

  final Widget child;

  /// The field is showing a validation error: the halo turns `error`.
  final bool error;

  /// Match the child's shape so the halo hugs it.
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final hue = error ? colors.error : colors.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: hue.withValues(
              alpha: Glows.alphaFor(Theme.of(context).brightness),
            ),
            blurRadius: Sizes.fieldGlowBlur,
            spreadRadius: Sizes.fieldGlowSpread,
          ),
        ],
      ),
      child: child,
    );
  }
}
