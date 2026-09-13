import 'package:flutter/material.dart';

/// The type scale (DESIGN-NOTES.md §3 two-typeface split).
///
/// **Headings, big numbers and code use Space Grotesk** ([_heading]) — the
/// "crisp modern-SaaS character" face. **Body and UI text use Manrope**
/// ([_body]) — a clean, highly legible neutral sans. Both are bundled variable
/// fonts (`assets/fonts/`); Flutter maps `fontWeight` onto their `wght` axis.
/// Non-Latin glyphs neither face covers fall back to the system font, so the
/// ~80-locale coverage is preserved.
///
/// **Never write `fontSize` in a screen.** Never write `fontWeight` on a themed
/// style either — the token carries it. To colour text, use
/// `.copyWith(color: <role>)`.
abstract final class AppText {
  static const _heading = 'SpaceGrotesk';
  static const _body = 'Manrope';
  /// Heroes only — the auth screen's, and My Schedule's time-reactive band.
  ///
  /// Widened from "auth hero only" on 2026-08-20. The hero band needed a size
  /// above `titleLarge`, which is the section-header size and would have left
  /// the band no larger than the "Today" header directly beneath it. Reusing
  /// this token rather than adding one keeps the scale at nine entries and adds
  /// nothing to verify — both uses are genuinely the largest thing on their
  /// screen, which is the whole definition of the slot.
  ///
  /// A THIRD sanctioned use was added with the Hearth redesign (UI-RULES.md
  /// §6.14): the Stats dashboard's single number-hero — a streak or a total the
  /// dashboard may lead with. Same test as the other two: it is genuinely the
  /// largest thing on its screen. It is still not a general-purpose "big text"
  /// slot — three heroes now, each earning it, and no more without the same
  /// justification.
  static const displaySmall = TextStyle(
    fontFamily: _heading,
    fontSize: 32,
    height: 40 / 32,
    fontWeight: FontWeight.w700,
  );

  /// Screen section headers.
  static const titleLarge = TextStyle(
    fontFamily: _heading,
    fontSize: 20,
    height: 28 / 20,
    fontWeight: FontWeight.w600,
  );

  /// Card titles. **All of them** — the old UI had 18 on two screens and 17 on
  /// a third for the same element. That is the drift this token prevents.
  static const titleMedium = TextStyle(
    fontFamily: _heading,
    fontSize: 17,
    height: 24 / 17,
    fontWeight: FontWeight.w600,
  );

  /// Default body.
  static const bodyLarge = TextStyle(
    fontFamily: _body,
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w400,
  );

  /// Dense body.
  static const bodyMedium = TextStyle(
    fontFamily: _body,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
  );

  /// Buttons.
  static const labelLarge = TextStyle(
    fontFamily: _body,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w600,
  );

  /// Hints and secondary prose — anything the user reads as a sentence.
  static const bodySmall = TextStyle(
    fontFamily: _body,
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w400,
  );

  /// Metadata: timestamps, timezone labels, counts. Not for prose.
  static const labelSmall = TextStyle(
    fontFamily: _body,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w500,
  );

  /// Invite codes and any code-like string. Reached via `context.codeDisplay`.
  static const codeDisplay = TextStyle(
    fontFamily: _heading,
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w700,
    letterSpacing: 3,
  );

  /// The letter drawn inside an avatar when there is no picture.
  ///
  /// **Not a tenth entry in the type scale**, and it must not be used as one.
  /// The scale is nine sizes for *text the user reads*; this is a letterform
  /// used as a graphic, filling a circle whose diameter is a layout token
  /// (`Sizes.avatarRow` / `avatarHeader` / `avatarEditable`). A fixed style
  /// cannot serve all three: `titleMedium` is right in a 40pt row and becomes a
  /// small letter adrift in a 96pt disc.
  ///
  /// So the size is derived from the diameter, which keeps the optical weight
  /// constant across every place an avatar appears. 0.42 is the ratio at which
  /// a capital's cap-height reads as filling the circle without touching its
  /// edge; `height: 1` removes the line-box padding that would otherwise push
  /// the letter off-centre.
  ///
  /// It lives here rather than in the widget because raw type values belong in
  /// this file — that is the whole of UI-RULES.md §1, and the lint enforces it.
  static TextStyle avatarInitial(double diameter) => TextStyle(
        fontFamily: _heading,
        fontSize: diameter * 0.42,
        height: 1,
        fontWeight: FontWeight.w600,
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
