import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// **The one** section header (UI-RULES.md §2.7, §3).
///
/// STRUCTURE, not state: a short rule above a `titleLarge` label. The rule is
/// line work, never a fill, which is what lets it carry colour without
/// competing with a status badge.
///
/// Green by default. [attention] switches the rule to orange and is **only**
/// legitimate when the section's content is genuinely attention-bearing — a
/// pending queue, a "waiting on you" group. Structure never invents a new
/// meaning for orange; it points at attention that is really there. If you
/// find yourself reaching for `attention: true` to add emphasis, don't.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key, this.attention = false});

  final String label;

  /// Orange rule instead of green. See the class doc — this is a claim that the
  /// section holds something waiting on the user, not a styling choice.
  final bool attention;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Vertical only — the parent owns horizontal inset, so this sits flush
      // with the list or form it heads.
      padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: Sizes.sectionRuleWidth,
            height: Sizes.ruleWidth,
            color: attention ? context.attention : context.colors.primary,
          ),
          const SizedBox(height: Space.sm),
          Text(label, style: context.text.titleLarge),
        ],
      ),
    );
  }
}
