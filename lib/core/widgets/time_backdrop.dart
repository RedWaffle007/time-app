import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// The ambient, app-wide backdrop: a faint, tiled pattern of hand-drawn-style
/// **time-related** line marks — clocks, alarm clocks, books, pencils,
/// hourglasses, calendars, paperclips — tinted in the brand green and the
/// categorical accents.
///
/// This is Checkmate's take on DESIGN-NOTES §8's `AutomotiveBackdrop`: same idea
/// (a subtle texture that ties the *subject* to an otherwise-clean surface,
/// never competing with content), but the subject is *time and study*, not cars.
///
/// It sits BENEATH every route. The app's scaffolds are transparent
/// (`scaffoldBackgroundColor: transparent`, wired in [AppTheme]), so this shows
/// through the gutters between the opaque cards. Cards, app bars, sheets and
/// dialogs keep their own opaque fills, so the backdrop never lowers contrast on
/// content — it only textures the empty space.
class TimeBackdrop extends StatelessWidget {
  const TimeBackdrop({super.key, required this.child});

  final Widget child;

  /// One app-wide layer survives navigator, dialog and sheet transitions.
  static const backdropKey = ValueKey<String>('app-time-backdrop');
  static const painterKey = ValueKey<String>('time-backdrop-painter');

  /// Light is intentionally just visible in route gutters; dark retains its
  /// established balance.
  static const lightMarkOpacity = 0.085;
  static const darkMarkOpacity = 0.10;

  static const _lightAccents = <Color>[
    AppColors.lightPrimary,
    AppColors.lightTurquoise,
    AppColors.lightGolden,
    AppColors.lightViolet,
    AppColors.lightPink,
  ];
  static const _darkAccents = <Color>[
    AppColors.darkPrimary,
    AppColors.darkTurquoise,
    AppColors.darkGolden,
    AppColors.darkViolet,
    AppColors.darkPink,
  ];
  static const _lightPainter = _TimeMarksPainter(
    colors: _lightAccents,
    opacity: lightMarkOpacity,
  );
  static const _darkPainter = _TimeMarksPainter(
    colors: _darkAccents,
    opacity: darkMarkOpacity,
  );

  @override
  Widget build(BuildContext context) {
    final cs = context.colors;
    final dark = cs.brightness == Brightness.dark;

    // Real chroma, held to a whisper of opacity. The old light value (0.055)
    // disappeared against the near-white scaffold on most LCDs; this remains
    // beneath opaque content but is now perceptible in the route gutters.
    // Dark deliberately keeps its established balance.
    final painter = dark ? _darkPainter : _lightPainter;

    return DecoratedBox(
      // The opaque ground beneath the transparent scaffolds. Read from the raw
      // palette, not `scaffoldBackgroundColor` (which is transparent so this
      // backdrop can show through every route).
      decoration: BoxDecoration(
        color: dark ? AppColors.darkBackground : AppColors.lightBackground,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: painterKey,
                  isComplex: true,
                  willChange: false,
                  painter: painter,
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Tiles the time-themed glyphs across the canvas in a staggered grid, each
/// nudged and rotated deterministically so the field reads as hand-placed rather
/// than a rubber-stamped lattice.
class _TimeMarksPainter extends CustomPainter {
  const _TimeMarksPainter({required this.colors, required this.opacity});

  final List<Color> colors;
  final double opacity;

  /// The glyph vocabulary, in draw order. Cycled across the grid.
  static const _glyphCount = 7;

  @override
  void paint(Canvas canvas, Size size) {
    const tile = 132.0; // spacing between marks
    const glyph = 40.0; // nominal glyph box

    final cols = (size.width / tile).ceil() + 1;
    final rows = (size.height / tile).ceil() + 1;

    var i = 0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        // A stable pseudo-random from the cell coordinates — no per-frame drift.
        final seed = (r * 73856093) ^ (c * 19349663);
        final rand = math.Random(seed);

        // Every other row is offset half a tile — a brick layout, less grid-like.
        final dx =
            c * tile +
            (r.isOdd ? tile / 2 : 0) +
            (rand.nextDouble() - 0.5) * 26;
        final dy = r * tile + (rand.nextDouble() - 0.5) * 26;

        final color = colors[i % colors.length];
        final angle = (rand.nextDouble() - 0.5) * 0.5; // ±~14°
        final scale = 0.8 + rand.nextDouble() * 0.5;

        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = 2.0
          ..color = color.withValues(alpha: opacity);

        canvas.save();
        canvas.translate(dx, dy);
        canvas.rotate(angle);
        canvas.scale(scale);
        _drawGlyph(canvas, i % _glyphCount, glyph, paint);
        canvas.restore();

        i++;
      }
    }
  }

  void _drawGlyph(Canvas canvas, int kind, double s, Paint p) {
    final h = s / 2;
    switch (kind) {
      case 0:
        _clock(canvas, h, p);
      case 1:
        _alarmClock(canvas, h, p);
      case 2:
        _book(canvas, h, p);
      case 3:
        _pencil(canvas, h, p);
      case 4:
        _hourglass(canvas, h, p);
      case 5:
        _calendar(canvas, h, p);
      default:
        _paperclip(canvas, h, p);
    }
  }

  void _clock(Canvas canvas, double r, Paint p) {
    canvas.drawCircle(Offset.zero, r, p);
    // hands
    canvas.drawLine(Offset.zero, Offset(0, -r * 0.6), p);
    canvas.drawLine(Offset.zero, Offset(r * 0.45, r * 0.2), p);
  }

  void _alarmClock(Canvas canvas, double r, Paint p) {
    final face = r * 0.78;
    canvas.drawCircle(Offset.zero, face, p);
    canvas.drawLine(Offset.zero, Offset(0, -face * 0.55), p);
    canvas.drawLine(Offset.zero, Offset(face * 0.4, face * 0.15), p);
    // two bells on top
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(-face * 0.75, -face * 0.75),
        radius: r * 0.28,
      ),
      math.pi,
      math.pi,
      false,
      p,
    );
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(face * 0.75, -face * 0.75),
        radius: r * 0.28,
      ),
      math.pi,
      math.pi,
      false,
      p,
    );
    // legs
    canvas.drawLine(
      Offset(-face * 0.6, face * 0.75),
      Offset(-face * 0.85, face),
      p,
    );
    canvas.drawLine(
      Offset(face * 0.6, face * 0.75),
      Offset(face * 0.85, face),
      p,
    );
  }

  void _book(Canvas canvas, double r, Paint p) {
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: r * 2,
      height: r * 1.5,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      p,
    );
    // spine
    canvas.drawLine(Offset(0, -r * 0.75), Offset(0, r * 0.75), p);
    // page lines
    canvas.drawLine(
      Offset(-r * 0.7, -r * 0.25),
      Offset(-r * 0.2, -r * 0.25),
      p,
    );
    canvas.drawLine(Offset(r * 0.2, -r * 0.25), Offset(r * 0.7, -r * 0.25), p);
  }

  void _pencil(Canvas canvas, double r, Paint p) {
    // a pencil at a diagonal: shaft + tip
    final a = Offset(-r * 0.8, r * 0.8);
    final b = Offset(r * 0.55, -r * 0.55);
    canvas.drawLine(a, b, p);
    // body edges
    final perp = (b - a);
    final n = Offset(-perp.dy, perp.dx);
    final len = n.distance;
    final off = Offset(n.dx / len, n.dy / len) * (r * 0.18);
    canvas.drawLine(a + off, b + off, p);
    canvas.drawLine(a - off, b - off, p);
    // tip
    final tip = Offset(r * 0.85, -r * 0.85);
    canvas.drawLine(b + off, tip, p);
    canvas.drawLine(b - off, tip, p);
  }

  void _hourglass(Canvas canvas, double r, Paint p) {
    final path = Path()
      ..moveTo(-r * 0.7, -r)
      ..lineTo(r * 0.7, -r)
      ..lineTo(-r * 0.55, r * 0.05)
      ..lineTo(r * 0.7, r)
      ..lineTo(-r * 0.7, r)
      ..lineTo(r * 0.55, -r * 0.05)
      ..close();
    canvas.drawPath(path, p);
  }

  void _calendar(Canvas canvas, double r, Paint p) {
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: r * 1.8,
      height: r * 1.8,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      p,
    );
    // header rule
    canvas.drawLine(Offset(-r * 0.9, -r * 0.5), Offset(r * 0.9, -r * 0.5), p);
    // binding rings
    canvas.drawLine(Offset(-r * 0.4, -r), Offset(-r * 0.4, -r * 1.25), p);
    canvas.drawLine(Offset(r * 0.4, -r), Offset(r * 0.4, -r * 1.25), p);
  }

  void _paperclip(Canvas canvas, double r, Paint p) {
    final path = Path()
      ..moveTo(-r * 0.35, r * 0.9)
      ..lineTo(-r * 0.35, -r * 0.55)
      ..arcToPoint(
        Offset(r * 0.35, -r * 0.55),
        radius: Radius.circular(r * 0.35),
      )
      ..lineTo(r * 0.35, r * 0.55)
      ..arcToPoint(Offset(0, r * 0.9), radius: Radius.circular(r * 0.35))
      ..lineTo(0, -r * 0.2);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_TimeMarksPainter old) =>
      old.opacity != opacity || old.colors != colors;
}
