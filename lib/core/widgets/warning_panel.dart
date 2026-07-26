import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// **The one** warning panel (UI-RULES.md §6.3). Never rebuild this inline —
/// same reasoning as [StatusBadge] in `status_style.dart`: a recipe copied into
/// a screen is a recipe that drifts.
///
/// Warning is the attention family pitched up from pending — solid left rule +
/// icon + a larger fill — not a separate amber hue. The old `Colors.amber` sat
/// ~10 degrees off our orange and read as a muddy near-miss.
///
/// The fill is `attentionContainerStrong`, NOT the badge tint — this is the
/// largest attention surface in the app, and rendering it at size showed the
/// badge tint separating 3.13:1 from the background in dark but only 1.19:1 in
/// light. The strong role matches dark's separation in both modes without
/// dragging the Pending badge up with it (UI-RULES.md §2.4).
///
/// The rule and icon use `onAttentionContainer`, not `attention`, which measures
/// only 2.69:1 on this fill in dark — below even the 3:1 non-text floor.
///
/// A value tuned on a Pending badge is not proven here.
/// `lib/dev/theme_preview.dart` renders this at size next to the badges for
/// exactly that reason.
class WarningPanel extends StatelessWidget {
  const WarningPanel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final fg = context.onAttentionContainer;
    return Container(
      margin: const EdgeInsets.only(top: Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: context.attentionContainerStrong,
        borderRadius: Radii.sm,
        border: Border(left: BorderSide(color: fg, width: Sizes.ruleWidth)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.warning, color: fg, size: Sizes.inlineIcon),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(text, style: context.text.bodySmall?.copyWith(color: fg)),
          ),
        ],
      ),
    );
  }
}
