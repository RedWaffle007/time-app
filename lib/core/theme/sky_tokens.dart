import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The hero band's sky — the time-reactive header on My Schedule.
///
/// **This is the second file permitted to hold hex literals**, alongside
/// `app_colors.dart` (UI-RULES.md §1). The values here are not roles and never
/// become roles: nothing in this file may be read by a screen as `primary`,
/// `attention` or `error`, and nothing outside the hero band may read this file
/// at all.
///
/// ## The one property that makes this verifiable
///
/// **Hue and warmth travel with the clock; luminance does not.** Light mode's
/// sky stays light at midnight and dark mode's stays dark at noon — brightness
/// follows the theme, colour follows the hour. That is what lets the band reuse
/// `onSurface` for its text instead of inventing a time-varying text colour,
/// and it is why a contrast figure for this band can be computed at all.
///
/// A sky that spans deep night to bright midday (the shape the prototype used)
/// forces its text colour to flip with the hour and puts contrast wherever it
/// lands — measured as low as 2.19:1. Do not widen these luminance bands.
///
/// ## Verified
///
/// Swept every 0.1h × every 5% down the band — 5,061 samples per ramp — against
/// the mode's `onSurface`. Worst point found:
///
/// | | light | dark |
/// |---|---|---|
/// | `onSurface` on any sky value | **5.71** | **5.91** |
/// | luminance band | 0.295 – 0.841 | 0.010 – 0.096 |
///
/// Floor is 4.5:1. Sampling the keyframes alone is NOT sufficient — two safe
/// keyframes can interpolate through an unsafe midpoint, and a gradient has a
/// second axis besides time. Re-run the full sweep if any value below changes.
///
/// `onSurfaceVariant` is deliberately **not** supported on the sky: holding it
/// above 4.5:1 would squeeze the light band to L ≥ 0.567 and flatten the whole
/// journey. Hero text is `onSurface` only; hierarchy comes from size and weight.
abstract final class SkyRamp {
  /// Light mode. Stays light around the clock — night is a dusky mauve, not a
  /// dark sky. Built from the app's own two hues: sage through the middle of
  /// the day, terracotta at the edges, mauve at night. It cannot introduce a
  /// third hue because it is made of the two the palette already owns.
  static const light = <_SkyKey>[
    _SkyKey(0, Color(0xFF9D909C), Color(0xFFB8ABB2)),
    _SkyKey(5.5, Color(0xFFC7A3AA), Color(0xFFF2CBA8)),
    _SkyKey(8, Color(0xFFC8D1C2), Color(0xFFF2E7D2)),
    _SkyKey(13, Color(0xFFB5CDC2), Color(0xFFE4EFE7)),
    _SkyKey(17.5, Color(0xFFE0C0A2), Color(0xFFF7E0BB)),
    _SkyKey(20, Color(0xFFB79AA1), Color(0xFFE2C0AA)),
    _SkyKey(24, Color(0xFF9D909C), Color(0xFFB8ABB2)),
  ];

  /// Dark mode — re-picked, not darkened from light. Same hue journey, held
  /// under L 0.096 so `darkOnSurface` clears AA everywhere.
  static const dark = <_SkyKey>[
    _SkyKey(0, Color(0xFF1B1728), Color(0xFF2E233A)),
    _SkyKey(5.5, Color(0xFF32222F), Color(0xFF63403C)),
    _SkyKey(8, Color(0xFF23332C), Color(0xFF3E5446)),
    _SkyKey(13, Color(0xFF1F3C33), Color(0xFF316050)),
    _SkyKey(17.5, Color(0xFF3E2619), Color(0xFF6B3C21)),
    _SkyKey(20, Color(0xFF2C1D30), Color(0xFF502F36)),
    _SkyKey(24, Color(0xFF1B1728), Color(0xFF2E233A)),
  ];
}

/// The sun and moon.
///
/// **Re-picked per mode, for opposite reasons.** In dark the body reads by its
/// own luminance. In light it cannot — the sky is light at every hour by
/// design, so no disc separates from it by fill alone (the best warm fill
/// measured 1.61:1). Form therefore comes from a **rim**, which is the same
/// answer §5 already gives for cards: definition from structure, not from a
/// tonal jump.
///
/// Rim values are held to the 3:1 non-text floor across the hours their body is
/// actually visible — the sun 06:18–18:42, the moon the complement.
///
/// | rim | vs its sky |
/// |---|---|
/// | light sun `#7A5214` | 3.33 |
/// | light moon `#463E56` | 3.31 |
/// | dark sun `#F0AE4F` | 3.72 |
/// | dark moon `#A9B2C9` | 4.17 |
///
/// The light sun's rim is pitched **golden (≈40°), deliberately away from the
/// terracotta `attention` hue (≈24°)**. A burnt-amber rim measured equally well
/// but sat close enough to `#8A4A25` to invite reading the sun as a state
/// colour. Nothing in the hero may look like a role.
abstract final class CelestialColors {
  static const lightSun = CelestialPaint(
    fill: Color(0xFFF6D9A6),
    core: Color(0xFFFFF3D6),
    rim: Color(0xFF7A5214),
    detail: Color(0xFFE7C489),
  );
  static const lightMoon = CelestialPaint(
    fill: Color(0xFFF7F3FA),
    core: Color(0xFFFFFFFF),
    rim: Color(0xFF463E56),
    detail: Color(0xFFD9D0E2),
  );
  static const darkSun = CelestialPaint(
    fill: Color(0xFFFFD98A),
    core: Color(0xFFFFF6DC),
    rim: Color(0xFFF0AE4F),
    detail: Color(0xFFF7C877),
  );
  static const darkMoon = CelestialPaint(
    fill: Color(0xFFE8ECF7),
    core: Color(0xFFFBFCFF),
    rim: Color(0xFFA9B2C9),
    detail: Color(0xFFC3CBDD),
  );
}

/// The four values one celestial body is drawn from.
@immutable
class CelestialPaint {
  const CelestialPaint({
    required this.fill,
    required this.core,
    required this.rim,
    required this.detail,
  });

  /// The body's main mass.
  final Color fill;

  /// The lit highlight, offset toward the upper left.
  final Color core;

  /// The limb. This is what makes the shape read in light mode.
  final Color rim;

  /// Craters (moon) and the inner warm falloff (sun).
  final Color detail;
}

/// A resolved sky for one instant: the gradient, plus where the sun or moon is
/// and which one it is.
@immutable
class SkyPalette {
  const SkyPalette({
    required this.top,
    required this.bottom,
    required this.isDaytime,
    required this.across,
    required this.altitude,
    required this.body,
  });

  final Color top;
  final Color bottom;

  /// True when the sun is up, false when the moon is.
  final bool isDaytime;

  /// 0 at rise, 1 at set — position along the arc.
  final double across;

  /// 0 at the horizon, 1 at the top of the arc.
  final double altitude;

  final CelestialPaint body;

  /// Below this the body is at the horizon and is not drawn at all, rather than
  /// being clipped by the band's edge.
  bool get bodyIsVisible => altitude > 0.05;
}

/// Sunrise and sunset, as fractional hours.
///
/// Fixed, not computed from latitude: the band is a mood and an orientation
/// cue, not an almanac. A real solar model would make the sky depend on the
/// user's location, which is data this app does not collect and has no reason
/// to start collecting.
const double _sunrise = 6.3;
const double _sunset = 18.7;

/// The device's local time as a fractional hour in `[0, 24)`.
double hourOfDay(DateTime now) => now.hour + now.minute / 60;

/// The sky at [hour] for [brightness].
SkyPalette skyAt(Brightness brightness, double hour) {
  final isDark = brightness == Brightness.dark;
  final keys = isDark ? SkyRamp.dark : SkyRamp.light;
  final h = hour.clamp(0.0, 24.0);

  var a = keys.first;
  var b = keys.last;
  for (var i = 0; i < keys.length - 1; i++) {
    if (h >= keys[i].hour && h <= keys[i + 1].hour) {
      a = keys[i];
      b = keys[i + 1];
      break;
    }
  }
  final span = b.hour - a.hour;
  final t = span == 0 ? 0.0 : (h - a.hour) / span;

  final isDaytime = h >= _sunrise && h <= _sunset;
  final double progress;
  if (isDaytime) {
    progress = (h - _sunrise) / (_sunset - _sunrise);
  } else {
    // Night wraps midnight, so map it onto one continuous 0..1 run.
    final nightLength = 24 - _sunset + _sunrise;
    final elapsed = h >= _sunset ? h - _sunset : h + (24 - _sunset);
    progress = elapsed / nightLength;
  }

  return SkyPalette(
    top: Color.lerp(a.top, b.top, t)!,
    bottom: Color.lerp(a.bottom, b.bottom, t)!,
    isDaytime: isDaytime,
    across: progress,
    altitude: math.sin(progress * math.pi),
    body: isDaytime
        ? (isDark ? CelestialColors.darkSun : CelestialColors.lightSun)
        : (isDark ? CelestialColors.darkMoon : CelestialColors.lightMoon),
  );
}

@immutable
class _SkyKey {
  const _SkyKey(this.hour, this.top, this.bottom);
  final double hour;
  final Color top;
  final Color bottom;
}
