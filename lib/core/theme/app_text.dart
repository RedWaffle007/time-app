import 'package:flutter/material.dart';

/// The type scale. See UI-RULES.md §3.
///
/// System font — no custom family. `supportedLocales` covers ~80 locales and the
/// system font is the only thing guaranteed to have the glyphs.
///
/// **Never write `fontSize` in a screen.** Never write `fontWeight` on a themed
/// style either — the token carries it. To colour text, use
/// `.copyWith(color: <role>)`.
abstract final class AppText {
  /// Auth hero only.
  static const displaySmall = TextStyle(
    fontSize: 32,
    height: 40 / 32,
    fontWeight: FontWeight.w700,
  );

  /// Screen section headers.
  static const titleLarge = TextStyle(
    fontSize: 20,
    height: 28 / 20,
    fontWeight: FontWeight.w600,
  );

  /// Card titles. **All of them** — the old UI had 18 on two screens and 17 on
  /// a third for the same element. That is the drift this token prevents.
  static const titleMedium = TextStyle(
    fontSize: 17,
    height: 24 / 17,
    fontWeight: FontWeight.w600,
  );

  /// Default body.
  static const bodyLarge = TextStyle(
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w400,
  );

  /// Dense body.
  static const bodyMedium = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
  );

  /// Buttons.
  static const labelLarge = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w600,
  );

  /// Hints and secondary prose — anything the user reads as a sentence.
  static const bodySmall = TextStyle(
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w400,
  );

  /// Metadata: timestamps, timezone labels, counts. Not for prose.
  static const labelSmall = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w500,
  );

  /// Invite codes and any code-like string. Reached via `context.codeDisplay`.
  static const codeDisplay = TextStyle(
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w700,
    letterSpacing: 3,
  );

  static const textTheme = TextTheme(
    displaySmall: displaySmall,
    titleLarge: titleLarge,
    titleMedium: titleMedium,
    bodyLarge: bodyLarge,
    bodyMedium: bodyMedium,
    labelLarge: labelLarge,
    bodySmall: bodySmall,
    labelSmall: labelSmall,
  );
}

/// Type tokens that have no slot in Material's [TextTheme].
@immutable
class AppTypeExtension extends ThemeExtension<AppTypeExtension> {
  const AppTypeExtension({required this.codeDisplay});

  final TextStyle codeDisplay;

  static const standard = AppTypeExtension(codeDisplay: AppText.codeDisplay);

  @override
  AppTypeExtension copyWith({TextStyle? codeDisplay}) =>
      AppTypeExtension(codeDisplay: codeDisplay ?? this.codeDisplay);

  @override
  AppTypeExtension lerp(AppTypeExtension? other, double t) {
    if (other == null) return this;
    return AppTypeExtension(
      codeDisplay: TextStyle.lerp(codeDisplay, other.codeDisplay, t)!,
    );
  }
}
