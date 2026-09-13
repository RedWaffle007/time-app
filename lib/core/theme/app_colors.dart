import 'package:flutter/material.dart';

/// Raw colour values for the app, light and dark.
///
/// **This is the ONLY file in the codebase where a hex literal may appear.**
/// Everything else reads a semantic role off `Theme.of(context).colorScheme` or
/// the [AppSemanticColors] extension. See UI-RULES.md §1 and §2.
///
/// The palette is the DealerPulse system (DESIGN-NOTES.md §2): a **green brand**
/// of real chroma over a **green-tinted neutral ramp** — the background carries
/// a trace of the brand hue rather than being pure white or terracotta-warm.
/// Green (~148°) owns action and affirmation; a **burnt orange** (~22°) owns
/// attention and pending state. Light is pitched brighter and more colourful
/// than the old sage palette (the previous light mode read flat); dark keeps the
/// same hues, re-picked lighter and more chromatic so the green glows on black.
///
/// A categorical accent set ([turquoise], [golden], [violet], [pink]) is defined
/// for charts and multi-series marks — real chroma reserved for *meaning*, never
/// sprinkled onto chrome.
///
/// Dark is **re-picked, not inverted**: chroma drops and lightness rises,
/// because saturated hues vibrate on dark surfaces.
abstract final class AppColors {
  // ---------------------------------------------------------------- light ---

  /// Scaffold background. A faint green tint (DESIGN-NOTES §2) — "branded but
  /// quiet", not pure white and no longer terracotta-warm.
  static const lightBackground = Color(0xFFEAF8EF);

  /// Card and sheet fill — crisp near-white so cards lift cleanly off the
  /// tinted scaffold; the hairline border still carries the edge.
  static const lightSurface = Color(0xFFF9FFFB);
  static const lightSurfaceContainer = Color(0xFFD8F3DF);
  static const lightSurfaceContainerHigh = Color(0xFFC8E9D0);

  static const lightOnSurface = Color(0xFF141A15);
  static const lightOnSurfaceVariant = Color(0xFF4B574D);

  /// Meaningful borders only. NEVER a text colour.
  static const lightOutline = Color(0xFF6E7A70);

  /// Decorative hairlines only. Never a border that carries meaning.
  static const lightOutlineVariant = Color(0xFFD1DCD2);

  // Green — action and affirmation. The DealerPulse brand green, richer and more
  // vivid than the old sage so light mode reads with colour.
  static const lightPrimary = Color(0xFF1B7A3D);
  static const lightOnPrimary = Color(0xFFFFFFFF);
  static const lightPrimaryContainer = Color(0xFF9FE5B4);
  static const lightOnPrimaryContainer = Color(0xFF04250F);

  // `secondary` deliberately reuses the green family rather than introducing a
  // third set of values.

  // Burnt orange — attention and pending state. Also carries warning (no amber).
  static const lightAttention = Color(0xFFB4400C);
  static const lightOnAttention = Color(0xFFFFFFFF);

  /// Pending's badge tint — a warm orange that out-pulls Approved.
  static const lightAttentionContainer = Color(0xFFFFD2B2);

  /// The warning panel's fill — attention pitched up (UI-RULES.md §2.4).
  static const lightAttentionContainerStrong = Color(0xFFFF9A58);

  static const lightOnAttentionContainer = Color(0xFF441C06);

  // Red — rationed to destructive actions and system errors (UI-RULES.md §2.5).
  static const lightError = Color(0xFFB3261E);
  static const lightOnError = Color(0xFFFFFFFF);
  static const lightErrorContainer = Color(0xFFFFD3D0);
  static const lightOnErrorContainer = Color(0xFF410E0B);

  // ----------------------------------------------------------------- dark ---

  /// Near-black with a faint green cast — the dark twin of the light scaffold's
  /// tint, so the two modes share a family.
  static const darkBackground = Color(0xFF0F1511);

  /// Card and sheet fill — a small tonal step off the scaffold; the border
  /// carries the edge.
  static const darkSurface = Color(0xFF18201A);
  static const darkSurfaceContainer = Color(0xFF18201A);
  static const darkSurfaceContainerHigh = Color(0xFF232D25);

  static const darkOnSurface = Color(0xFFE6EEE7);
  static const darkOnSurfaceVariant = Color(0xFFAFBBB1);

  static const darkOutline = Color(0xFF8A958C);
  static const darkOutlineVariant = Color(0xFF39453B);

  // A lighter, more chromatic green so it glows against the dark surface
  // (DESIGN-NOTES §2).
  static const darkPrimary = Color(0xFF56CE7E);
  static const darkOnPrimary = Color(0xFF00391B);
  static const darkPrimaryContainer = Color(0xFF1E5233);
  static const darkOnPrimaryContainer = Color(0xFFB6F2C6);

  static const darkAttention = Color(0xFFF0A56E);
  static const darkOnAttention = Color(0xFF491E05);

  /// Pending's badge tint in dark — a burnt orange that reads as orange, not
  /// brown, and still sits below the solid Done win state.
  static const darkAttentionContainer = Color(0xFFA5551E);

  /// The warning panel's fill. Dark already carries the separation the panel
  /// needs, so this holds the same value as the badge tint (UI-RULES.md §2.4).
  static const darkAttentionContainerStrong = Color(0xFFA5551E);

  static const darkOnAttentionContainer = Color(0xFFFDE9D8);

  static const darkError = Color(0xFFF2B8B5);
  static const darkOnError = Color(0xFF601410);
  static const darkErrorContainer = Color(0xFF8C1D18);
  static const darkOnErrorContainer = Color(0xFFF9DEDC);

  // ---------------------------------------------------- categorical accents ---
  // Real chroma reserved for meaning: chart series and multi-series marks
  // (DESIGN-NOTES §2). Never used for chrome. Light/dark twins.
  static const lightTurquoise = Color(0xFF0E7C86);
  static const darkTurquoise = Color(0xFF5AD0D8);
  static const lightGolden = Color(0xFF8A6200);
  static const darkGolden = Color(0xFFE8C15A);
  static const lightViolet = Color(0xFF6D48C4);
  static const darkViolet = Color(0xFFB9A0F0);
  static const lightPink = Color(0xFFC03271);
  static const darkPink = Color(0xFFF08AB4);
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
      attentionContainer: Color.lerp(
        attentionContainer,
        other.attentionContainer,
        t,
      )!,
      attentionContainerStrong: Color.lerp(
        attentionContainerStrong,
        other.attentionContainerStrong,
        t,
      )!,
      onAttentionContainer: Color.lerp(
        onAttentionContainer,
        other.onAttentionContainer,
        t,
      )!,
    );
  }
}
