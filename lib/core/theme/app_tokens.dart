import 'package:flutter/material.dart';

/// Spacing on a 4pt grid. See UI-RULES.md §4.
///
/// `6`, `10`, and `20` are off-grid and banned — the old UI used all three.
/// Migration: `6 → xs`, `10 → md`, `20 → xl`.
abstract final class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  /// Screen padding for forms.
  static const EdgeInsets screenForm = EdgeInsets.all(xl);

  /// Screen padding for lists.
  static const EdgeInsets screenList = EdgeInsets.all(lg);

  /// The canonical card margin (UI-RULES.md §6.1).
  static const EdgeInsets cardMargin =
      EdgeInsets.symmetric(horizontal: md, vertical: sm);

  /// The canonical card interior padding.
  static const EdgeInsets cardPadding = EdgeInsets.all(lg);
}

/// Corner radii. See UI-RULES.md §4.
abstract final class Radii {
  /// Inputs, small tints, the warning panel.
  static const BorderRadius sm = BorderRadius.all(Radius.circular(8));

  /// Cards and containers.
  static const BorderRadius md = BorderRadius.all(Radius.circular(12));

  /// Dialogs and bottom sheets.
  static const BorderRadius lg = BorderRadius.all(Radius.circular(16));

  /// Badges, chips, filled buttons.
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

/// Elevation. Flat by default — see UI-RULES.md §5.
///
/// Anything that floats *over* content gets a shadow; anything that sits *in*
/// the flow does not. Cards, list rows, badges, panels and inputs are all
/// [flat], defined by a 1px `outlineVariant` border instead of a shadow.
abstract final class Elevations {
  /// Cards, list rows, badges, panels, inputs.
  static const double flat = 0;

  /// Navigation bar.
  static const double nav = 2;

  /// Dialogs, bottom sheets, snackbars.
  static const double floating = 3;
}

/// Motion. Calm means short and unfussy — no bounce, no overshoot.
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Curve curve = Curves.easeOutCubic;
}

/// Sizes that recur across recipes.
abstract final class Sizes {
  /// Minimum touch target (UI-RULES.md §7).
  static const double touchTarget = 48;

  /// Empty-state icon (UI-RULES.md §6.5).
  static const double emptyStateIcon = 40;

  /// A list-tile leading icon and an app-bar action icon (UI-RULES.md §6.6).
  /// Both are Material's default 24 — named so the value is stated rather than
  /// inherited implicitly, and so changing it is one edit.
  static const double listIcon = 24;
  static const double appBarIcon = 24;

  /// Inline icon paired with body text, e.g. the warning panel.
  static const double inlineIcon = 20;

  /// Icon inside a status badge, sized to `labelSmall`.
  static const double badgeIcon = 14;

  /// The spinner that replaces a button's label while it is working. Sized to
  /// the label, so the button doesn't change height mid-action.
  static const double buttonSpinner = 20;

  /// The warning panel's left rule (UI-RULES.md §6.3) and the section header's
  /// rule (§2.7) — both are 3px line work.
  static const double ruleWidth = 3;

  /// Length of a section header's rule (UI-RULES.md §2.7).
  static const double sectionRuleWidth = 28;

  /// Hairline border used everywhere flat surfaces need an edge.
  static const double hairline = 1;

  /// Height of a determinate progress bar (UI-RULES.md §6.7).
  ///
  /// Material's default is 4, which on a phone reads as a hairline rule rather
  /// than as a filling shape — and the one place this is used, a 130MB
  /// download, is a bar someone actually watches. 8 is thick enough to see the
  /// fill move without becoming a slab.
  static const double progressBar = 8;
}
