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

  /// The two intentional bars under the wordmark — top deep green, bottom dark
  /// burnt orange. Deliberately fixed here (not theme roles) for the same reason
  /// as the black surface: the launch identity looks the same in light and dark.
  /// Both are mid-dark but saturated, so they still read on pure black.
  static const Color lineTop = Color(0xFF1B7A3D);
  static const Color lineBottom = Color(0xFFC2410C);

  /// Thickness of each underline bar.
  static const double lineThickness = 4;

  /// The wordmark's typeface: **Anton** (OFL, bundled at
  /// `assets/fonts/Anton-Regular.ttf`) — the closest free match to Supercell's
  /// heavy, condensed, uppercase wordmark. Rendered on a SINGLE line (the one
  /// departure from Supercell, which stacks three).
  ///
  /// The `fontSize` here is a nominal design size; the reveal wraps the text in
  /// a `FittedBox`, so it scales down to fit narrow screens without ever
  /// overflowing. Kept in this file because inline `fontSize` is §1-banned in
  /// feature code and this is where the raw value is allowed to live.
  static const TextStyle wordmarkStyle = TextStyle(
    fontFamily: 'Anton',
    color: wordmark,
    fontSize: 40,
    letterSpacing: 4,
    height: 1.0,
    // Explicitly none: the splash sits in MaterialApp.builder, above the app's
    // text theme, so an unset decoration falls back to Flutter's yellow double
    // underline. The two intentional bars are drawn separately (lineTop/Bottom).
    decoration: TextDecoration.none,
    // The soft Supercell-style bloom, BAKED as text shadows rather than an
    // animated `ImageFilter.blur`. A per-frame gaussian blur on text janked the
    // reveal on-device; shadows rasterize with the glyphs and cost nothing per
    // frame, so the fade stays perfectly smooth. Two layers = a tight inner halo
    // plus a wide soft glow.
    shadows: [
      Shadow(color: Color(0x59FFFFFF), blurRadius: 18),
      Shadow(color: Color(0x33FFFFFF), blurRadius: 44),
    ],
  );

  /// A faint status line ("Preparing your app…") shown near the bottom only when
  /// the reveal is still holding on the readiness gate after the intro. Muted
  /// white so it reads as a quiet note, never competing with the wordmark.
  static const TextStyle waitingStyle = TextStyle(
    fontFamily: 'Anton',
    color: Color(0x99FFFFFF),
    fontSize: 12,
    letterSpacing: 2,
    height: 1.0,
    decoration: TextDecoration.none,
  );
}
