import 'package:flutter/material.dart';

/// Raw colour values for the app, light and dark.
///
/// **This is the ONLY file in the codebase where a hex literal may appear.**
/// Everything else reads a semantic role off `Theme.of(context).colorScheme` or
/// the [AppSemanticColors] extension. See UI-RULES.md §1 and §2.
///
/// The palette is two hues of equal presence with divided duty:
/// green (~157°, sage) owns action and affirmation; orange (~24°, terracotta)
/// owns attention and pending state. Saturation is held to 25–45% throughout —
/// calm and muted, never punchy.
///
/// Dark is **re-picked, not inverted**: chroma drops and lightness rises,
/// because saturated hues vibrate on dark surfaces.
///
/// Every text pairing here is verified against WCAG AA (4.5:1) in both modes.
/// Changing any value requires re-running the contrast check in UI-RULES.md §7.
abstract final class AppColors {
  // ---------------------------------------------------------------- light ---

  /// Scaffold background. Carries a deliberate terracotta cast — the neutral
  /// ramp is where "orange is present on every screen" is actually paid for,
  /// without any element becoming orange (UI-RULES.md §2.7, "temperature").
  static const lightBackground = Color(0xFFFAF5EE);

  /// Card and sheet fill. Only a 1.06 step off the scaffold — separation comes
  /// from the border, not a tonal jump (UI-RULES.md §2.2).
  static const lightSurface = Color(0xFFFFFCF8);
  static const lightSurfaceContainer = Color(0xFFF4EDE3);
  static const lightSurfaceContainerHigh = Color(0xFFEDE3D6);

  static const lightOnSurface = Color(0xFF1C1A16);
  static const lightOnSurfaceVariant = Color(0xFF57534B);

  /// Meaningful borders only. NEVER a text colour — 3.74:1 on the darkest
  /// container (UI-RULES.md §2.6).
  static const lightOutline = Color(0xFF7A7266);

  /// Decorative hairlines only — 1.44:1. Never a border that carries meaning.
  static const lightOutlineVariant = Color(0xFFDED3C3);

  // Green — action and affirmation.
  static const lightPrimary = Color(0xFF356150);
  static const lightOnPrimary = Color(0xFFFFFFFF);
  static const lightPrimaryContainer = Color(0xFFD5E6DB);
  static const lightOnPrimaryContainer = Color(0xFF14352A);

  // `secondary` deliberately reuses the green family rather than introducing a
  // third set of values. The palette is two hues; Material needs a `secondary`
  // slot filled, and filling it with unverified new values would put unchecked
  // contrast pairings into the system. See UI-RULES.md §2.1.

  // Orange — attention and pending state. Also carries warning (no amber).
  static const lightAttention = Color(0xFF8A4A25);
  static const lightOnAttention = Color(0xFFFFFFFF);
  /// Raised from `#F7E3D4` on 2026-07-25, closing the fix left open when dark's
  /// Pending was raised: at that value the light chip did not out-pull Approved
  /// at all (1.24 vs Approved's 1.30). Now 2.05 off the card — a **1.62x** pull,
  /// matching dark's 1.62x exactly. Text pairing measures 6.78:1.
  static const lightAttentionContainer = Color(0xFFE6A574);

  /// The warning panel's fill — attention pitched up (UI-RULES.md §2.4).
  ///
  /// Same hue (26 degrees) and saturation (69%) as the tint above; only
  /// lightness moves. Rendering the panel at size showed it separating 3.13:1
  /// from the background in dark but only 1.19:1 in light — a warning is the
  /// most important thing on a screen, and light was the weak mode. This value
  /// matches dark's separation (2.71:1 off the card, against dark's 2.66).
  ///
  /// It is a SEPARATE role rather than a raise of [lightAttentionContainer]
  /// because the badge shares that token: at that strength the light Pending
  /// chip would pull 2.14x over Approved, harder than dark's 1.62x. The badge
  /// tint was instead raised on its own terms — see [lightAttentionContainer].
  ///
  /// `#D9792F` (matching dark's 3.13:1 off the *scaffold*) was rejected — its
  /// text pairing measures 4.56:1, 0.06 off the floor.
  static const lightAttentionContainerStrong = Color(0xFFDD8643);

  static const lightOnAttentionContainer = Color(0xFF43220F);

  // Red — rationed to destructive actions and system errors (UI-RULES.md §2.5).
  static const lightError = Color(0xFF9C332C);
  static const lightOnError = Color(0xFFFFFFFF);
  static const lightErrorContainer = Color(0xFFF8DEDA);
  static const lightOnErrorContainer = Color(0xFF4A100D);

  // ----------------------------------------------------------------- dark ---

  /// Warmed hard on 2026-07-25: ~2.4x the warm chroma of the original
  /// `#16171A`. A subtler first pass rendered as indistinguishable from
  /// neutral, which defeated the point (UI-RULES.md §2.7).
  static const darkBackground = Color(0xFF1F1916);

  /// Card and sheet fill — a 1.14 step off the scaffold.
  static const darkSurface = Color(0xFF2B2421);
  static const darkSurfaceContainer = Color(0xFF2B2421);
  static const darkSurfaceContainerHigh = Color(0xFF392F2A);

  static const darkOnSurface = Color(0xFFF0E8DC);
  static const darkOnSurfaceVariant = Color(0xFFC0B4A4);

  static const darkOutline = Color(0xFF9C9083);
  static const darkOutlineVariant = Color(0xFF4C4139);

  static const darkPrimary = Color(0xFF8CC6AB);
  static const darkOnPrimary = Color(0xFF0A2419);
  static const darkPrimaryContainer = Color(0xFF2A4E3F);
  static const darkOnPrimaryContainer = Color(0xFFB9E3CF);

  static const darkAttention = Color(0xFFE3A47C);
  static const darkOnAttention = Color(0xFF3D1E0C);

  /// Raised from `#5A3520` after the first on-device render: at that value the
  /// Pending chip read as a muted brown, not orange — only 1.49:1 off the card.
  /// Pending is the app's core attention state (the gap between proposed and
  /// resolved that the whole doctrine is built around), so it has to pull.
  ///
  /// 2.8x the luminance, chroma 0.64 -> 0.82, and 2.66:1 off the card. Still
  /// well below Done (7.83:1), so the solid win state stays the heaviest badge.
  static const darkAttentionContainer = Color(0xFF9C531C);

  /// **Deliberately identical to [darkAttentionContainer].** Dark already had
  /// the separation the warning panel needs (2.66:1 off the card) once Pending
  /// was raised; only light had to diverge. A role that holds the same value in
  /// one mode is the seam where the two modes legitimately differ (UI-RULES.md
  /// §2.4/§8), not a redundant token — and keeping it named means raising one
  /// mode later can't silently drag the other with it.
  static const darkAttentionContainerStrong = Color(0xFF9C531C);

  /// Brightened alongside the container: the old `#F3D3BC` drops to 4.05:1 on
  /// the lighter fill, under AA. This pairing measures 4.99:1.
  static const darkOnAttentionContainer = Color(0xFFFBEDE2);

  static const darkError = Color(0xFFEBA49E);
  static const darkOnError = Color(0xFF57120F);
  static const darkErrorContainer = Color(0xFF5C2320);
  static const darkOnErrorContainer = Color(0xFFF8D6D2);
}

/// The attention (orange) family, which Material's [ColorScheme] has no slot for.
///
/// It is *also* mapped onto `tertiary`/`tertiaryContainer` in [AppTheme] so
/// stock Material widgets can reach it, but call sites must read it from here —
/// `context.attention` says what it means; `colorScheme.tertiary` does not.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.attention,
    required this.onAttention,
    required this.attentionContainer,
    required this.attentionContainerStrong,
    required this.onAttentionContainer,
  });

  final Color attention;
  final Color onAttention;
  final Color attentionContainer;

  /// The warning panel's fill. Badges use [attentionContainer]; only the panel
  /// uses this. Text, rule and icon on BOTH fills are [onAttentionContainer] —
  /// there is no separate `on*Strong`.
  final Color attentionContainerStrong;

  final Color onAttentionContainer;

  static const light = AppSemanticColors(
    attention: AppColors.lightAttention,
    onAttention: AppColors.lightOnAttention,
    attentionContainer: AppColors.lightAttentionContainer,
    attentionContainerStrong: AppColors.lightAttentionContainerStrong,
    onAttentionContainer: AppColors.lightOnAttentionContainer,
  );

  static const dark = AppSemanticColors(
    attention: AppColors.darkAttention,
    onAttention: AppColors.darkOnAttention,
    attentionContainer: AppColors.darkAttentionContainer,
    attentionContainerStrong: AppColors.darkAttentionContainerStrong,
    onAttentionContainer: AppColors.darkOnAttentionContainer,
  );

  @override
  AppSemanticColors copyWith({
    Color? attention,
    Color? onAttention,
    Color? attentionContainer,
    Color? attentionContainerStrong,
    Color? onAttentionContainer,
  }) {
    return AppSemanticColors(
      attention: attention ?? this.attention,
      onAttention: onAttention ?? this.onAttention,
      attentionContainer: attentionContainer ?? this.attentionContainer,
      attentionContainerStrong:
          attentionContainerStrong ?? this.attentionContainerStrong,
      onAttentionContainer: onAttentionContainer ?? this.onAttentionContainer,
    );
  }

  @override
  AppSemanticColors lerp(AppSemanticColors? other, double t) {
    if (other == null) return this;
    return AppSemanticColors(
      attention: Color.lerp(attention, other.attention, t)!,
      onAttention: Color.lerp(onAttention, other.onAttention, t)!,
      attentionContainer:
          Color.lerp(attentionContainer, other.attentionContainer, t)!,
      attentionContainerStrong: Color.lerp(
          attentionContainerStrong, other.attentionContainerStrong, t)!,
      onAttentionContainer:
          Color.lerp(onAttentionContainer, other.onAttentionContainer, t)!,
    );
  }
}
