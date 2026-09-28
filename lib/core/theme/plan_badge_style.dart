import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/scheduling/domain/schedule_item.dart';
import 'app_colors.dart';
import 'app_theme.dart';
import 'app_tokens.dart';

/// Who a plan is between, from the viewer's side (UI-RULES.md §6.18).
enum PlanOwnership { sent, self, received }

/// [iAmTarget] = the viewer is the plan's target (it came from their own
/// items). A plan whose creator is its target is always [PlanOwnership.self].
PlanOwnership planOwnership(ScheduleItem item, {required bool iAmTarget}) {
  if (item.createdByUid == item.targetUid) return PlanOwnership.self;
  return iAmTarget ? PlanOwnership.received : PlanOwnership.sent;
}

/// The one-word label of each plan badge.
String planOwnershipLabel(PlanOwnership ownership) => switch (ownership) {
  PlanOwnership.sent => 'Sent',
  PlanOwnership.self => 'Self',
  PlanOwnership.received => 'Received',
};

const kGroupPlanBadgeLabel = 'Group';

/// The badge accents: the ONLY place these colours may be chosen (the
/// recorded exception to the two hues, DECISIONS.md "Plan badges").
Color planOwnershipColor(BuildContext context, PlanOwnership ownership) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (ownership) {
    PlanOwnership.sent => dark ? AppColors.darkBlue : AppColors.lightBlue,
    PlanOwnership.self => dark ? AppColors.darkViolet : AppColors.lightViolet,
    PlanOwnership.received => dark ? AppColors.darkPink : AppColors.lightPink,
  };
}

Color groupPlanBadgeColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? AppColors.darkGolden
    : AppColors.lightGolden;

/// A plan card's top-right badges: ownership, plus Group on a group plan.
class PlanBadges extends StatelessWidget {
  const PlanBadges({super.key, required this.item, required this.iAmTarget});

  final ScheduleItem item;
  final bool iAmTarget;

  @override
  Widget build(BuildContext context) {
    final ownership = planOwnership(item, iAmTarget: iAmTarget);
    return Wrap(
      spacing: Space.xs,
      runSpacing: Space.xs,
      alignment: WrapAlignment.end,
      children: [
        PlanBadge(
          key: ValueKey('plan-badge-${ownership.name}'),
          label: planOwnershipLabel(ownership),
          color: planOwnershipColor(context, ownership),
        ),
        if (item.groupId.isNotEmpty)
          PlanBadge(
            key: const ValueKey('plan-badge-group'),
            label: kGroupPlanBadgeLabel,
            color: groupPlanBadgeColor(context),
          ),
      ],
    );
  }
}

/// An outline-only pill with a metallic gradient border. One sheen sweep on
/// first build; none when the platform asks for reduced motion.
class PlanBadge extends StatefulWidget {
  const PlanBadge({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  State<PlanBadge> createState() => _PlanBadgeState();
}

class _PlanBadgeState extends State<PlanBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: Motion.sheen,
    value: 1,
  );
  bool _started = false;
  Timer? _next;

  /// The pause between sweeps. The shine REPEATS (device report 2026-09-28:
  /// a single sweep on first appearance was easy to miss, so "Sent" looked
  /// flat). Between sweeps nothing animates, so screens still settle.
  static const _pause = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    _sheen.addStatusListener((status) {
      if (status == AnimationStatus.completed) _scheduleNext();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _sweep();
  }

  void _sweep() {
    if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
    _sheen.forward(from: 0);
  }

  void _scheduleNext() {
    _next?.cancel();
    _next = Timer(_pause, _sweep);
  }

  @override
  void dispose() {
    _next?.cancel();
    _sheen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A bright highlight in both modes (toward white), so the sweep reads on
    // every accent — blue and gold included.
    final sheen = Color.lerp(widget.color, context.immersiveForeground, 0.8)!;
    return AnimatedBuilder(
      animation: _sheen,
      builder: (context, child) => CustomPaint(
        painter: _SheenBorderPainter(
          color: widget.color,
          sheen: sheen,
          // At rest the highlight sits a third of the way along, so the
          // border still reads as metallic without motion.
          position: _sheen.isAnimating ? _sheen.value : 0.33,
        ),
        child: child,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xs,
        ),
        child: Text(
          widget.label,
          style: context.text.labelSmall?.copyWith(
            color: widget.color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _SheenBorderPainter extends CustomPainter {
  _SheenBorderPainter({
    required this.color,
    required this.sheen,
    required this.position,
  });

  final Color color;
  final Color sheen;

  /// Where the highlight is, 0 (left) … 1 (right).
  final double position;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final inset = Sizes.badgeBorder / 2;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(inset),
      Radius.circular(size.height / 2),
    );
    final p = position.clamp(0.0, 1.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = Sizes.badgeBorder
      ..shader = LinearGradient(
        colors: [color, color, sheen, color, color],
        stops: [
          0,
          (p - 0.25).clamp(0.0, 1.0),
          p,
          (p + 0.25).clamp(0.0, 1.0),
          1,
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_SheenBorderPainter old) =>
      old.position != position || old.color != color || old.sheen != sheen;
}
