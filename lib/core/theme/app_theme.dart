import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_text.dart';
import 'app_tokens.dart';

/// The app's light and dark themes. See UI-RULES.md.
///
/// Everything visual is decided here so screens never decide it. A screen that
/// sets a colour, a font size, or an elevation is a screen that has drifted.
abstract final class AppTheme {
  static ThemeData get light => _build(
        colorScheme: _lightScheme,
        scaffoldBackground: AppColors.lightBackground,
        semantic: AppSemanticColors.light,
      );

  static ThemeData get dark => _build(
        colorScheme: _darkScheme,
        scaffoldBackground: AppColors.darkBackground,
        semantic: AppSemanticColors.dark,
      );

  // --------------------------------------------------------------- schemes ---

  /// `tertiary` carries the attention (orange) family so stock Material widgets
  /// can reach it. Screens must read it via `context.attention` instead — see
  /// [AppSemanticColors].
  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.lightPrimary,
    onPrimary: AppColors.lightOnPrimary,
    primaryContainer: AppColors.lightPrimaryContainer,
    onPrimaryContainer: AppColors.lightOnPrimaryContainer,
    secondary: AppColors.lightPrimary,
    onSecondary: AppColors.lightOnPrimary,
    secondaryContainer: AppColors.lightPrimaryContainer,
    onSecondaryContainer: AppColors.lightOnPrimaryContainer,
    tertiary: AppColors.lightAttention,
    onTertiary: AppColors.lightOnAttention,
    tertiaryContainer: AppColors.lightAttentionContainer,
    onTertiaryContainer: AppColors.lightOnAttentionContainer,
    error: AppColors.lightError,
    onError: AppColors.lightOnError,
    errorContainer: AppColors.lightErrorContainer,
    onErrorContainer: AppColors.lightOnErrorContainer,
    surface: AppColors.lightSurface,
    onSurface: AppColors.lightOnSurface,
    surfaceContainer: AppColors.lightSurfaceContainer,
    surfaceContainerHigh: AppColors.lightSurfaceContainerHigh,
    surfaceContainerHighest: AppColors.lightSurfaceContainerHigh,
    onSurfaceVariant: AppColors.lightOnSurfaceVariant,
    outline: AppColors.lightOutline,
    outlineVariant: AppColors.lightOutlineVariant,
  );

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.darkPrimary,
    onPrimary: AppColors.darkOnPrimary,
    primaryContainer: AppColors.darkPrimaryContainer,
    onPrimaryContainer: AppColors.darkOnPrimaryContainer,
    secondary: AppColors.darkPrimary,
    onSecondary: AppColors.darkOnPrimary,
    secondaryContainer: AppColors.darkPrimaryContainer,
    onSecondaryContainer: AppColors.darkOnPrimaryContainer,
    tertiary: AppColors.darkAttention,
    onTertiary: AppColors.darkOnAttention,
    tertiaryContainer: AppColors.darkAttentionContainer,
    onTertiaryContainer: AppColors.darkOnAttentionContainer,
    error: AppColors.darkError,
    onError: AppColors.darkOnError,
    errorContainer: AppColors.darkErrorContainer,
    onErrorContainer: AppColors.darkOnErrorContainer,
    surface: AppColors.darkSurface,
    onSurface: AppColors.darkOnSurface,
    surfaceContainer: AppColors.darkSurfaceContainer,
    surfaceContainerHigh: AppColors.darkSurfaceContainerHigh,
    surfaceContainerHighest: AppColors.darkSurfaceContainerHigh,
    onSurfaceVariant: AppColors.darkOnSurfaceVariant,
    outline: AppColors.darkOutline,
    outlineVariant: AppColors.darkOutlineVariant,
  );

  // ----------------------------------------------------------------- build ---

  static ThemeData _build({
    required ColorScheme colorScheme,
    required Color scaffoldBackground,
    required AppSemanticColors semantic,
  }) {
    final cs = colorScheme;

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: scaffoldBackground,
      textTheme: AppText.textTheme,
      extensions: [semantic, AppTypeExtension.standard],

      // Flat by default (UI-RULES.md §5): elevation 0 + a 1px outlineVariant
      // border. Shadows belong only to things that float over content.
      cardTheme: CardThemeData(
        elevation: Elevations.flat,
        color: cs.surface,
        margin: Space.cardMargin,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.md,
          side: BorderSide(color: cs.outlineVariant, width: Sizes.hairline),
        ),
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBackground,
        foregroundColor: cs.onSurface,
        elevation: Elevations.flat,
        scrolledUnderElevation: Elevations.flat,
        centerTitle: false,
        titleTextStyle: AppText.titleLarge.copyWith(color: cs.onSurface),
      ),

      navigationBarTheme: NavigationBarThemeData(
        elevation: Elevations.nav,
        backgroundColor: cs.surface,
        indicatorColor: cs.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          AppText.labelSmall.copyWith(color: cs.onSurface),
        ),
      ),

      // Green owns the primary action (UI-RULES.md §2.1). The FAB uses the
      // container tone rather than the solid fill — a full-strength green slab
      // is the loudest thing on screen and fights "calm".
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: Elevations.flat,
        backgroundColor: cs.primaryContainer,
        foregroundColor: cs.onPrimaryContainer,
        shape: const RoundedRectangleBorder(borderRadius: Radii.pill),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, Sizes.touchTarget),
          textStyle: AppText.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: Radii.pill),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, Sizes.touchTarget),
          textStyle: AppText.labelLarge,
          side: BorderSide(color: cs.outline, width: Sizes.hairline),
          shape: const RoundedRectangleBorder(borderRadius: Radii.pill),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, Sizes.touchTarget),
          textStyle: AppText.labelLarge,
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cs.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        border: OutlineInputBorder(
          borderRadius: Radii.sm,
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Radii.sm,
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Radii.sm,
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: Radii.sm,
          borderSide: BorderSide(color: cs.error),
        ),
        labelStyle: AppText.bodyMedium.copyWith(color: cs.onSurfaceVariant),
        hintStyle: AppText.bodyMedium.copyWith(color: cs.onSurfaceVariant),
      ),

      chipTheme: ChipThemeData(
        elevation: Elevations.flat,
        labelStyle: AppText.labelSmall,
        side: BorderSide(color: cs.outlineVariant, width: Sizes.hairline),
        shape: const RoundedRectangleBorder(borderRadius: Radii.pill),
      ),

      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        thickness: Sizes.hairline,
        space: Sizes.hairline,
      ),

      listTileTheme: ListTileThemeData(
        titleTextStyle: AppText.bodyLarge.copyWith(color: cs.onSurface),
        subtitleTextStyle: AppText.bodySmall.copyWith(color: cs.onSurfaceVariant),
        iconColor: cs.onSurfaceVariant,
      ),

      // Floats over content — one of the three shadow exceptions.
      dialogTheme: DialogThemeData(
        elevation: Elevations.floating,
        backgroundColor: cs.surface,
        shape: const RoundedRectangleBorder(borderRadius: Radii.lg),
        titleTextStyle: AppText.titleLarge.copyWith(color: cs.onSurface),
        contentTextStyle: AppText.bodyMedium.copyWith(color: cs.onSurface),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        elevation: Elevations.floating,
        backgroundColor: cs.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        elevation: Elevations.floating,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: Radii.sm),
        contentTextStyle: AppText.bodyMedium.copyWith(color: cs.onSurface),
        backgroundColor: cs.surfaceContainerHigh,
        actionTextColor: cs.primary,
      ),
    );
  }
}

/// Semantic reads for the tokens Material has no slot for.
///
/// `context.attention` says what it means; `colorScheme.tertiary` does not.
extension AppThemeContext on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;

  AppSemanticColors get _semantic =>
      Theme.of(this).extension<AppSemanticColors>()!;

  Color get attention => _semantic.attention;
  Color get onAttention => _semantic.onAttention;
  Color get attentionContainer => _semantic.attentionContainer;
  Color get attentionContainerStrong => _semantic.attentionContainerStrong;
  Color get onAttentionContainer => _semantic.onAttentionContainer;

  TextStyle get codeDisplay =>
      Theme.of(this).extension<AppTypeExtension>()!.codeDisplay;
}
