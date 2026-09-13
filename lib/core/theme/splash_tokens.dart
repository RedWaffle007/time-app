import 'package:flutter/widgets.dart';

/// Fixed brand constants for the cold-start reveal (`SplashOverlay`).
///
/// These are deliberately **theme-independent**: the reveal is a pure-black
/// (#000000) surface with a white wordmark in both light and dark, the way a
/// Supercell launch looks the same regardless of device theme. They therefore
/// do NOT belong in `app_colors.dart`'s light/dark roles — they are not roles,
/// they are the launch identity. They live here (in `core/theme`, which
/// UI-RULES §1 exempts) so the reveal widget in `features/splash` can stay free
/// of raw `Colors.*` / inline `fontSize` and pass the §1 lint.
class SplashTokens {
  const SplashTokens._();

  /// The reveal surface — true black, matching the native launch window
  /// (`android/.../launch_background.xml`) so nothing flashes between the two.
  static const Color background = Color(0xFF000000);

  /// The wordmark itself — pure white, emerging out of the black.
  static const Color wordmark = Color(0xFFFFFFFF);

  /// The soft bloom that blooms as the wordmark resolves. White; its opacity is
  /// animated by the reveal, so the constant is fully opaque.
  static const Color glow = Color(0xFFFFFFFF);

  /// The two intentional bars under the wordmark — top brand green, bottom
  /// burnt orange, the two DealerPulse brand accents (DESIGN-NOTES §2).
  /// Deliberately fixed here (not theme roles) for the same reason as the black
  /// surface: the launch identity looks the same in light and dark. Both are
  /// saturated, so they read against pure black.
  static const Color lineTop = Color(0xFF2FA35A);
  static const Color lineBottom = Color(0xFFEA6A2E);

  /// Thickness of each underline bar.
  static const double lineThickness = 4;

  /// The wordmark's typeface: **Space Grotesk** (OFL, variable, bundled at
  /// `assets/fonts/SpaceGrotesk.ttf`) — the "crisp modern-SaaS character" heading
  /// face from DESIGN-NOTES §3. It replaces Anton, which read as a heavy blob at
  /// wordmark size; Space Grotesk keeps every letter distinct so "CHECKMATE" is
  /// legible at a glance.
  ///
  /// The `fontSize` here is a nominal design size; the reveal wraps the text in
  /// a `FittedBox`, so it scales down to fit narrow screens without ever
  /// overflowing. Kept in this file because inline `fontSize` is §1-banned in
  /// feature code and this is where the raw value is allowed to live.
  static const TextStyle wordmarkStyle = TextStyle(
    fontFamily: 'SpaceGrotesk',
    color: wordmark,
    fontSize: 46,
    fontWeight: FontWeight.w700,
    fontVariations: [FontVariation('wght', 700)],
    // Tight, not sprawling — enough air to separate the letters without the
    // spacing that made the old wordmark hard to parse.
    letterSpacing: 2,
    height: 1.0,
    // Explicitly none: the splash sits in MaterialApp.builder, above the app's
    // text theme, so an unset decoration falls back to Flutter's yellow double
    // underline. The two intentional bars are drawn separately (lineTop/Bottom).
    decoration: TextDecoration.none,
    // A soft bloom BAKED as text shadows rather than an animated
    // `ImageFilter.blur`. A per-frame gaussian blur on text janked the reveal
    // on-device; shadows rasterize with the glyphs and cost nothing per frame,
    // so the fade stays perfectly smooth. Softer than before so it reads as a
    // glow, not a smear over the letterforms.
    shadows: [
      Shadow(color: Color(0x40FFFFFF), blurRadius: 16),
      Shadow(color: Color(0x24FFFFFF), blurRadius: 40),
    ],
  );

  /// The tagline beneath the two bars — "Mates Always Remember". Space Grotesk
  /// at a readable weight and modest tracking (the old Anton + heavy spacing was
  /// the source of the "hard to read" complaint). Warm off-white so it sits
  /// quietly under the wordmark without competing with it.
  static const Color tagline = Color(0xFFE9E4DA);
  static const TextStyle taglineStyle = TextStyle(
    fontFamily: 'SpaceGrotesk',
    color: tagline,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    fontVariations: [FontVariation('wght', 500)],
    letterSpacing: 3,
    height: 1.0,
    decoration: TextDecoration.none,
  );

  /// A faint status line ("App is loading…") shown near the bottom only when the
  /// reveal is still holding on the readiness gate after the intro. Muted white
  /// so it reads as a quiet note, never competing with the wordmark.
  static const TextStyle waitingStyle = TextStyle(
    fontFamily: 'SpaceGrotesk',
    color: Color(0x99FFFFFF),
    fontSize: 12,
    fontWeight: FontWeight.w500,
    fontVariations: [FontVariation('wght', 500)],
    letterSpacing: 2,
    height: 1.0,
    decoration: TextDecoration.none,
  );
}
