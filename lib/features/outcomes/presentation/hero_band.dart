import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/sky_tokens.dart';
import '../../scheduling/domain/schedule_item.dart';

/// The time-reactive band at the top of My Schedule.
///
/// Its job is to orient you in the day and name the next thing — nothing else.
/// It deliberately does **not** restate pending state: that already lives on the
/// nav badge and the section rule, and a second place to read it is a second
/// place for the two to disagree.
///
/// ## The rules it lives under
///
/// - **The sky is temperature, not structure and not state.** It is the neutral
///   ramp's terracotta cast made time-varying (UI-RULES.md §2.7), confined to
///   one band on one screen.
/// - **No semantic role appears here.** Not `primary`, not `attention`, not
///   `error`, in fill or in line work. The filled-vs-line firewall is untouched
///   because there is no semantic colour in the band to firewall — a sun disc
///   is imagery in a sky value, not a filled state.
/// - **Hero text is `onSurface`.** `onSurfaceVariant` is not safe on the sky
///   (see `sky_tokens.dart`), so hierarchy comes from size and weight instead.
///
/// It rebuilds once a minute, not continuously. The sky is a slow gradient and
/// an always-animating background would mean continuous repaint in an app whose
/// live risk is OEM power management.
class HeroBand extends StatefulWidget {
  const HeroBand({super.key, required this.nextItem});

  /// The next approved, un-acted item, or null when nothing is coming up.
  final ScheduleItem? nextItem;

  @override
  State<HeroBand> createState() => _HeroBandState();
}

class _HeroBandState extends State<HeroBand> {
  Timer? _tick;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// The phase word. Reinforces the sun/moon rather than relying on it —
  /// UI-RULES.md §2.6(3), the label informs and the imagery echoes it.
  String _phase(double hour) {
    if (hour >= 5 && hour < 11) return 'Morning';
    if (hour >= 11 && hour < 17) return 'Afternoon';
    if (hour >= 17 && hour < 20.5) return 'Evening';
    return 'Night';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final hour = hourOfDay(_now);
    final sky = skyAt(Theme.of(context).brightness, hour);
    final item = widget.nextItem;

    // The band grows with the user's text size. It cannot simply be `minHeight`
    // with a min-size Column — the layout wants the label pinned to the top and
    // the time to the bottom, which needs a bounded height for `Spacer`. At the
    // default scale this is exactly `Sizes.heroBand`; at 2.0 the content needs
    // 184dp and this yields 256.
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final bandHeight =
        Sizes.heroBand * (1 + (textScale - 1) * 0.6).clamp(1.0, 1.8);

    return AnimatedContainer(
      duration: Motion.normal,
      curve: Motion.curve,
      height: bandHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [sky.top, sky.bottom],
        ),
        // The band's own edge. The sky can land within 1.09 of the scaffold at
        // some hours, so it cannot be relied on to separate itself (§5).
        border: Border(
          bottom: BorderSide(
            color: colors.outlineVariant,
            width: Sizes.hairline,
          ),
        ),
      ),
      child: Stack(
        children: [
          if (sky.bodyIsVisible)
            Positioned.fill(
              child: CustomPaint(
                painter: _CelestialPainter(sky: sky),
                isComplex: false,
              ),
            ),
          Padding(
            padding: Space.cardPadding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The type keeps to the left; the arc keeps to the upper right.
                // Neither is allowed to wander into the other's half.
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${formatWallDate(context, _now)} · ${_phase(hour)}',
                        style: text.labelSmall?.copyWith(color: colors.onSurface),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Spacer(),
                      if (item == null)
                        Text(
                          'Nothing scheduled',
                          style:
                              text.titleLarge?.copyWith(color: colors.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      else ...[
                        // "Next task" names WHICH task is coming, not just the
                        // clock — one of possibly many future items, made explicit.
                        Text(
                          'Next task',
                          style: text.labelSmall
                              ?.copyWith(color: colors.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: Space.xs),
                        Text(
                          item.title,
                          style: text.titleLarge
                              ?.copyWith(color: colors.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: Space.xs),
                        Text(
                          // Date AND time together (in the item's own zone), so
                          // the next task is unambiguous when it isn't today.
                          formatInstant(
                            context,
                            item.scheduledInstantUtc,
                            item.timezone,
                          ),
                          style:
                              text.bodySmall?.copyWith(color: colors.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const Expanded(flex: 2, child: SizedBox.shrink()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws the sun or the moon on its arc.
///
/// The two are built differently on purpose. A sun and a moon rendered as two
/// similar discs is not a day/night cue at all — you have to compare colours to
/// tell them apart, which is exactly the failure mode §2.6(3) warns about. So
/// the sun is a **full radiant disc with a halo** and the moon is a **crescent
/// with craters**: they differ in *silhouette*, which reads instantly and keeps
/// reading for someone who cannot distinguish the two hues.
class _CelestialPainter extends CustomPainter {
  const _CelestialPainter({required this.sky});

  final SkyPalette sky;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Sizes.celestialRadius;
    // The arc is confined to the upper right so it never sits behind the type.
    final center = Offset(
      size.width * (0.58 + sky.across * 0.32),
      size.height * (0.42 - sky.altitude * 0.26),
    );

    sky.isDaytime
        ? _paintSun(canvas, center, r)
        : _paintMoon(canvas, center, r);
  }

  void _paintSun(Canvas canvas, Offset c, double r) {
    final body = sky.body;

    // Halo — the sun's own light, falling off to nothing. This is what a moon
    // never gets, so the two silhouettes stay distinct even at a glance.
    final haloRadius = r * 2.4;
    canvas.drawCircle(
      c,
      haloRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            body.fill.withValues(alpha: 0.55),
            body.fill.withValues(alpha: 0.0),
          ],
          stops: const [0.28, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: haloRadius)),
    );

    // The disc, lit from the upper left.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.4),
          colors: [body.core, body.fill, body.detail],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // The limb. In light mode this is the only thing separating the sun from a
    // pale sky (see CelestialColors).
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = Sizes.celestialRim
        ..color = body.rim,
    );
  }

  void _paintMoon(Canvas canvas, Offset c, double r) {
    final body = sky.body;

    // A far softer, tighter glow than the sun's — present so the moon does not
    // look pasted on, absent enough that it never reads as radiant.
    final haloRadius = r * 1.7;
    canvas.drawCircle(
      c,
      haloRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            body.fill.withValues(alpha: 0.28),
            body.fill.withValues(alpha: 0.0),
          ],
          stops: const [0.45, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: haloRadius)),
    );

    // The crescent: the disc minus a disc offset up and to the right. Kept at a
    // fat waxing crescent rather than a thin one — thin reads as a sliver of
    // nothing at this size, and leaves no room for the craters.
    final full = Path()..addOval(Rect.fromCircle(center: c, radius: r));
    final shadow = Path()
      ..addOval(
        Rect.fromCircle(
          center: c + Offset(r * 0.52, -r * 0.30),
          radius: r * 0.98,
        ),
      );
    final crescent = Path.combine(PathOperation.difference, full, shadow);

    canvas.drawPath(
      crescent,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, 0.1),
          colors: [body.core, body.fill],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // Craters, clipped to the lit crescent so none of them float in the shadow.
    canvas.save();
    canvas.clipPath(crescent);
    final crater = Paint()..color = body.detail;
    canvas.drawCircle(c + Offset(-r * 0.44, -r * 0.16), r * 0.17, crater);
    canvas.drawCircle(c + Offset(-r * 0.22, r * 0.36), r * 0.12, crater);
    canvas.drawCircle(c + Offset(-r * 0.56, r * 0.30), r * 0.09, crater);
    canvas.restore();

    canvas.drawPath(
      crescent,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = Sizes.celestialRim
        ..color = body.rim,
    );
  }

  @override
  bool shouldRepaint(_CelestialPainter old) =>
      old.sky.across != sky.across ||
      old.sky.isDaytime != sky.isDaytime ||
      old.sky.body != sky.body;
}
