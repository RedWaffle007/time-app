import 'package:flutter/material.dart';

import '../../features/scheduling/domain/schedule_item.dart';
import 'app_icons.dart';
import 'app_theme.dart';
import 'app_tokens.dart';

/// **The one mapping** from a domain status to its appearance. See UI-RULES.md
/// §2.3.
///
/// Before this file existed, `planner_activity_screen.dart` and
/// `outcome_screen.dart` each had their own private `switch` over the same
/// domain concepts, with different answers. Never write a local status switch —
/// add the case here.
///
/// The doctrine (UI-RULES.md §2.1): green owns action and affirmation, orange
/// owns attention and pending state. Rejected and Skipped are **not** errors —
/// they are legitimate outcomes of the consent model, so they are neutral, never
/// red. Red is rationed to destructive actions and system failures.
enum StatusTreatment {
  /// Orange or green container fill with matching on-container text.
  tinted,

  /// Solid `primary` fill — the strongest badge. The win state only.
  solid,

  /// Transparent fill, `outline` border, `onSurfaceVariant` text.
  ///
  /// All four neutral statuses share this one treatment: the *label*
  /// differentiates them, so the colour does not need to. A dimmed variant was
  /// designed and rejected — it measured 4.43:1 in dark mode, under AA. Do not
  /// reintroduce tonal dimming to distinguish neutral statuses.
  neutral,
}

@immutable
class StatusStyle {
  const StatusStyle({
    required this.label,
    required this.treatment,
    required this.foreground,
    required this.background,
    this.border,
    this.icon,
  });

  final String label;
  final StatusTreatment treatment;
  final Color foreground;
  final Color background;

  /// Non-null only for [StatusTreatment.neutral], where the border is the
  /// badge's only structure — so it uses `outline`, never `outlineVariant`
  /// (which measures 1.42:1 in dark and would be invisible). UI-RULES.md §2.6.
  final Color? border;

  final IconData? icon;
}

/// The approval status of a planned item.
StatusStyle statusStyle(BuildContext context, ScheduleItemStatus status) {
  final cs = context.colors;
  switch (status) {
    // Waiting on the target to decide — the definition of "attention".
    case ScheduleItemStatus.pending:
      return StatusStyle(
        label: 'Pending',
        treatment: StatusTreatment.tinted,
        foreground: context.onAttentionContainer,
        background: context.attentionContainer,
        icon: AppIcons.pending,
      );
    case ScheduleItemStatus.approved:
      return StatusStyle(
        label: 'Approved',
        treatment: StatusTreatment.tinted,
        foreground: cs.onPrimaryContainer,
        background: cs.primaryContainer,
        icon: AppIcons.approved,
      );
    // Neutral, not red: rejecting a plan is the consent model working.
    case ScheduleItemStatus.rejected:
      return _neutral(cs, 'Rejected', AppIcons.rejected);
    case ScheduleItemStatus.cancelled:
      return _neutral(cs, 'Cancelled', AppIcons.cancelled);
    case ScheduleItemStatus.withdrawn:
      return _neutral(cs, 'Withdrawn', AppIcons.withdrawn);
  }
}

/// What the target did once the item came due.
StatusStyle outcomeStyle(BuildContext context, OutcomeResult result) {
  final cs = context.colors;
  switch (result) {
    // The win state — the only solid badge in the system.
    case OutcomeResult.done:
      return StatusStyle(
        label: 'Done',
        treatment: StatusTreatment.solid,
        foreground: cs.onPrimary,
        background: cs.primary,
        icon: AppIcons.done,
      );
    // Skipping is a legitimate outcome, not a failure. Neutral, never red.
    case OutcomeResult.skipped:
      return _neutral(cs, 'Skipped', AppIcons.skipped);
  }
}

/// Outcome presentation with item-level context. `Done (Late)` is derived from
/// the permanent alarm-time unavailability fact; it is never a third outcome.
StatusStyle itemOutcomeStyle(BuildContext context, ScheduleItem item) {
  final outcome = item.outcome;
  if (outcome == null) {
    throw ArgumentError.value(item, 'item', 'must have an outcome');
  }
  final base = outcomeStyle(context, outcome.result);
  if (outcome.result != OutcomeResult.done || !item.wasUnavailableAtAlarmTime) {
    return base;
  }
  return StatusStyle(
    label: 'Done (Late)',
    treatment: base.treatment,
    foreground: base.foreground,
    background: base.background,
    border: base.border,
    icon: base.icon,
  );
}

StatusStyle _neutral(ColorScheme cs, String label, IconData icon) =>
    StatusStyle(
      label: label,
      treatment: StatusTreatment.neutral,
      foreground: cs.onSurfaceVariant,
      background: Colors.transparent,
      border: cs.outline,
      icon: icon,
    );

/// A count of things waiting on the user, drawn on a navigation destination.
///
/// This lives here, next to the status badge, because it is a **filled orange
/// pill — state, not structure** (UI-RULES.md §2.7). The firewall says orange
/// fills exist only in the widgets that own state, so putting it anywhere else
/// would either break the rule or force an exception into the lint.
///
/// Renders nothing at zero: an empty count is not an attention state, and a
/// permanently-visible orange dot would be exactly the decorative orange the
/// doctrine rations.
class PendingCountBadge extends StatelessWidget {
  const PendingCountBadge({
    super.key,
    required this.count,
    required this.child,
  });

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child;
    return Badge(
      backgroundColor: context.attentionContainerStrong,
      textColor: context.onAttentionContainer,
      label: Text('$count', style: context.text.labelSmall),
      child: child,
    );
  }
}

/// Alpha of the attention halo per brightness (UI-RULES.md §6.2a): the dark
/// ground needs more to read as a glow rather than a smudge.
abstract final class AttentionGlow {
  static double alphaFor(Brightness brightness) =>
      brightness == Brightness.dark ? 0.6 : 0.45;
}

/// A soft `attention` halo behind a control while something waits on it
/// (UI-RULES.md §6.2a). Static by design. Lives here because it expresses
/// attention STATE, like [PendingCountBadge] which it always accompanies.
class PendingAttentionGlow extends StatelessWidget {
  const PendingAttentionGlow({
    super.key,
    required this.active,
    required this.child,
  });

  static const glowKey = ValueKey('pending-attention-glow');

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    final alpha = AttentionGlow.alphaFor(Theme.of(context).brightness);
    return DecoratedBox(
      key: glowKey,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: context.attention.withValues(alpha: alpha),
            blurRadius: Sizes.attentionGlowBlur,
            spreadRadius: Sizes.attentionGlowSpread,
          ),
        ],
      ),
      child: child,
    );
  }
}

/// The Pending approvals app-bar action: the icon carries the real count and
/// glows while anything is pending (UI-RULES.md §6.2a). One widget so every
/// place that opens the queue looks and reads the same.
class PendingApprovalsAction extends StatelessWidget {
  const PendingApprovalsAction({
    super.key,
    required this.count,
    required this.onPressed,
  });

  final int count;
  final VoidCallback onPressed;

  static String tooltipFor(int count) =>
      count > 0 ? 'Pending approvals, $count waiting' : 'Pending approvals';

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltipFor(count),
      onPressed: onPressed,
      icon: PendingAttentionGlow(
        active: count > 0,
        child: PendingCountBadge(
          count: count,
          child: const Icon(AppIcons.approvals),
        ),
      ),
    );
  }
}

/// The canonical status badge (UI-RULES.md §6.2).
///
/// Always carries its text label: colour reinforces state, it never informs on
/// its own (UI-RULES.md §2.6).
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.style, this.showIcon = false});

  StatusBadge.status(
    ScheduleItemStatus status,
    BuildContext context, {
    super.key,
  }) : style = statusStyle(context, status),
       showIcon = false;

  StatusBadge.outcome(OutcomeResult result, BuildContext context, {super.key})
    : style = outcomeStyle(context, result),
      showIcon = true;

  StatusBadge.itemOutcome(ScheduleItem item, BuildContext context, {super.key})
    : assert(item.outcome != null),
      style = itemOutcomeStyle(context, item),
      showIcon = true;

  final StatusStyle style;
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.xs,
      ),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: Radii.pill,
        border: style.border == null
            ? null
            : Border.all(color: style.border!, width: Sizes.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon && style.icon != null) ...[
            Icon(style.icon, size: Sizes.badgeIcon, color: style.foreground),
            const SizedBox(width: Space.xs),
          ],
          Text(
            style.label,
            style: context.text.labelSmall?.copyWith(color: style.foreground),
          ),
        ],
      ),
    );
  }
}
