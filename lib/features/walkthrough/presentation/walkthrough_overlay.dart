import 'package:flutter/material.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';

/// The per-step copy for the first-run orientation tour — one short line each,
/// in **spatial bottom-bar order**: Plan · Track · ⊕voice · Stats · You.
///
/// Pure data with no keys or widgets, so it is unit-testable on its own
/// (`walkthrough_test.dart`). `HomeShell` pairs each entry, by index, with the
/// `GlobalKey` of the bar item it points at — see [WalkthroughStep].
class WalkthroughStepCopy {
  const WalkthroughStepCopy(this.heading, this.body);
  final String heading;
  final String body;
}

/// The five steps. Order is deliberate and must match the order the bar items'
/// keys are supplied in `HomeShell`.
const kWalkthroughStepCopy = <WalkthroughStepCopy>[
  WalkthroughStepCopy(
    'Plan',
    'Your schedule, in three tabs — My Schedule, Activity, Groups. Tap the ＋ '
        'button (bottom-right) to plan an item, on any of them.',
  ),
  WalkthroughStepCopy(
    'Track',
    "Log time you've already spent. Tap the ＋ button (bottom-right) to add an "
        'entry, and see where your hours go.',
  ),
  WalkthroughStepCopy(
    'Speak to create',
    'The centre mic: tap and talk to log time or plan a reminder, hands-free — '
        'you review it before anything saves.',
  ),
  WalkthroughStepCopy(
    'Stats',
    'Your totals, streaks, follow-through and on-time rate at a glance.',
  ),
  WalkthroughStepCopy(
    'You',
    'Everything else lives here: Profile, Friends, Calendar, Language practice, '
        '“How this app works”, and reminder permissions.',
  ),
];

/// One resolved step: the copy plus the live target to spotlight and the shape
/// of that spotlight (the FAB is circular; a pillar is a rounded rect).
class WalkthroughStep {
  const WalkthroughStep({
    required this.copy,
    required this.targetKey,
    required this.spotlightRadius,
  });
  final WalkthroughStepCopy copy;
  final GlobalKey targetKey;
  final BorderRadius spotlightRadius;
}

/// The coach-mark overlay: a dimmed scrim with a spotlight cut out around the
/// current target, a tooltip card above it with a downward arrow, and
/// Skip / Next controls. **Custom, not a package** — so every value comes from
/// `app_tokens.dart` and it passes the UI-RULES §1 lint (UI-RULES.md §6.13).
///
/// It is a full-screen sibling stacked OVER `HomeShell`'s `Scaffold`, so it
/// covers the bottom bar and the docked FAB — the very things it points at,
/// which a body-level overlay could not reach.
///
/// Skippable at any step; tapping the dimmed area advances (the mainstream
/// gesture), and every exit — Skip or the final Done — calls [onDismiss] once.
class WalkthroughScrim extends StatefulWidget {
  const WalkthroughScrim({
    super.key,
    required this.steps,
    required this.onDismiss,
  });

  final List<WalkthroughStep> steps;

  /// Called exactly once when the tour ends (Skip or Done). `HomeShell` hides
  /// the scrim and records completion.
  final VoidCallback onDismiss;

  @override
  State<WalkthroughScrim> createState() => _WalkthroughScrimState();
}

class _WalkthroughScrimState extends State<WalkthroughScrim> {
  int _index = 0;

  /// Gap between the spotlit target and the arrow tip.
  static const double _arrowGap = Space.sm;
  static const double _arrowHeight = Space.sm;
  static const double _arrowWidth = Space.lg;

  /// How far the spotlight is inflated past the target's own bounds.
  static const double _spotlightPad = Space.sm;

  @override
  void initState() {
    super.initState();
    // The bar is already laid out (it is persistent), so target rects resolve on
    // the first build — but rebuild once post-frame as a belt-and-braces guard
    // for the case where they somehow are not measured yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _next() {
    if (_index >= widget.steps.length - 1) {
      widget.onDismiss();
      return;
    }
    setState(() => _index++);
  }

  void _back() {
    if (_index == 0) return;
    setState(() => _index--);
  }

  Rect? _targetRect(WalkthroughStep step) {
    final box = step.targetKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_index];
    final scrimColor = context.colors.scrim.withValues(alpha: 0.72);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.normal,
      curve: Motion.curve,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final target = _targetRect(step);
          final hole = target?.inflate(_spotlightPad);

          return Stack(
            children: [
              // Tap the dimmed area to advance; opaque so nothing behind the
              // tour is reachable while it is up.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _next,
                  child: CustomPaint(
                    painter: _SpotlightPainter(
                      hole: hole,
                      radius: step.spotlightRadius,
                      color: scrimColor,
                    ),
                  ),
                ),
              ),
              if (hole != null) ..._coachMark(context, size, hole, step),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _coachMark(
    BuildContext context,
    Size size,
    Rect hole,
    WalkthroughStep step,
  ) {
    final arrowTipY = hole.top - _arrowGap;
    final arrowTopY = arrowTipY - _arrowHeight;
    final arrowLeft = (hole.center.dx - _arrowWidth / 2)
        .clamp(Space.lg, size.width - Space.lg - _arrowWidth);

    return [
      // The tooltip card, spanning the width above the target.
      Positioned(
        left: Space.lg,
        right: Space.lg,
        bottom: size.height - arrowTopY,
        child: GestureDetector(
          // Absorb taps on the card so they don't bubble to the advance-on-tap
          // scrim; the buttons still fire on their own.
          onTap: () {},
          child: _CoachCard(
            step: step.copy,
            index: _index,
            total: widget.steps.length,
            onSkip: widget.onDismiss,
            onNext: _next,
            // Null on the first step hides Back — nowhere to go.
            onBack: _index == 0 ? null : _back,
          ),
        ),
      ),
      // The downward arrow from the card to the target.
      Positioned(
        left: arrowLeft,
        bottom: size.height - arrowTipY,
        width: _arrowWidth,
        height: _arrowHeight,
        child: CustomPaint(
          painter: _ArrowPainter(color: context.colors.surface),
        ),
      ),
    ];
  }
}

/// The card body — heading, one line of copy, a step counter and the controls.
class _CoachCard extends StatelessWidget {
  const _CoachCard({
    required this.step,
    required this.index,
    required this.total,
    required this.onSkip,
    required this.onNext,
    required this.onBack,
  });

  final WalkthroughStepCopy step;
  final int index;
  final int total;
  final VoidCallback onSkip;
  final VoidCallback onNext;

  /// Null on the first step — Back is hidden when there is nowhere to go back to.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final isLast = index == total - 1;
    return Card(
      elevation: Elevations.floating,
      child: Padding(
        padding: Space.cardPadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              step.heading,
              style: context.text.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Space.xs),
            Text(step.body, style: context.text.bodyMedium),
            const SizedBox(height: Space.md),
            Row(
              children: [
                Text(
                  '${index + 1} / $total',
                  style: context.text.labelSmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                // Back — a leading arrow, shown from step 2 onward so the user
                // can revisit a previous explanation.
                if (onBack != null) ...[
                  TextButton.icon(
                    onPressed: onBack,
                    icon: const Icon(AppIcons.stepBack),
                    label: const Text('Back'),
                  ),
                  const SizedBox(width: Space.sm),
                ],
                TextButton(
                  onPressed: onSkip,
                  child: const Text('Skip'),
                ),
                const SizedBox(width: Space.sm),
                // Next carries a trailing forward arrow; on the last step it is
                // the plain "Done" that finishes the tour.
                isLast
                    ? FilledButton(
                        onPressed: onNext,
                        child: const Text('Done'),
                      )
                    : FilledButton.icon(
                        onPressed: onNext,
                        icon: const Icon(AppIcons.stepForward),
                        label: const Text('Next'),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Fills the screen with the scrim colour, punching a rounded hole so the
/// spotlit target shows through unmodified.
class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter({
    required this.hole,
    required this.radius,
    required this.color,
  });

  final Rect? hole;
  final BorderRadius radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final screen = Offset.zero & size;
    if (hole == null) {
      canvas.drawRect(screen, paint);
      return;
    }
    final full = Path()..addRect(screen);
    final cut = Path()..addRRect(radius.toRRect(hole!));
    canvas.drawPath(
      Path.combine(PathOperation.difference, full, cut),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.hole != hole || old.radius != radius || old.color != color;
}

/// A small downward triangle, matching the card's surface, pointing at the
/// target.
class _ArrowPainter extends CustomPainter {
  const _ArrowPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color;
}
