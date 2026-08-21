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

  /// The time-reactive hero band at the top of My Schedule.
  ///
  /// Sized to hold `labelSmall` + `displaySmall` + `bodySmall` with `Space.lg`
  /// padding and still leave the sky visible above the type — the band is a
  /// sky with a caption, not a header with a tint.
  static const double heroBand = 160;

  /// Radius of the sun or moon in the hero band.
  static const double celestialRadius = 17;

  /// Profile-picture diameters (UI-RULES.md §6.6 — an avatar is an *image*,
  /// not an icon, so it is sized here rather than with the icon tokens).
  ///
  /// Three sizes, and no more: a list row, a screen header, and the editable
  /// one on the edit form. Each is a place an avatar actually appears — adding
  /// a fourth means a fourth place, which is a design question before it is a
  /// token question.
  ///
  /// [avatarRow] is deliberately just under [touchTarget]: a list row's leading
  /// slot is 40 by Material convention, and the row itself supplies the 48pt
  /// target, so sizing the image to the target would push every row taller.
  static const double avatarRow = 40;
  static const double avatarHeader = 72;
  static const double avatarEditable = 96;

  /// A stat tile's minimum width, used by the wrapping stats grid.
  ///
  /// Wide enough for "Plans made for others" over two lines at `labelSmall`
  /// plus a `titleLarge` value, so the tile count per row falls from three to
  /// two to one as the screen narrows instead of clipping a label.
  static const double statTileMinWidth = 148;

  /// **The calendar** (UI-RULES.md §6.10).
  ///
  /// [calendarCellHeight] is the 48dp TOUCH TARGET, not a layout preference: a
  /// day cell is how a date is selected. 44 was drawn first and fits a six-week
  /// month more comfortably; it is also under the §7 floor, so it lost. Do not
  /// shrink this to fit more weeks on screen.
  static const double calendarCellHeight = 48;

  /// One item's dot in a day cell, and the strip they sit in.
  ///
  /// The strip is reserved whether or not a day has items, so cells do not
  /// change height as the month pages past — a grid that reflows under the
  /// finger is hard to aim at.
  ///
  /// 16, not the dot's own 6: past four items the strip shows a `+n` count
  /// instead of more dots, and 16 is `labelSmall`'s line height. Sizing this to
  /// the dot would clip that count. Day number (20) + gap (4) + strip (16) =
  /// 40, inside [calendarCellHeight]'s 48 with room for padding.
  static const double calendarMarkerDot = 6;
  static const double calendarMarkerRow = 16;

  /// The day view's hour-label column, and the minimum height of one hour row.
  ///
  /// Equal on purpose: an empty hour is a square of whitespace, which is what
  /// makes a gap in the day legible as a gap. The row grows past this when it
  /// holds items — it is a rail, not a proportional grid, because a
  /// `ScheduleItem` has no duration to be proportional to.
  static const double calendarHourGutter = 56;
  static const double calendarHourRow = 56;

  /// The celestial body's limb. Deliberately heavier than [hairline]: in light
  /// mode the sky is light at every hour, so the rim — not the fill — is what
  /// makes the shape read at all.
  static const double celestialRim = 1.5;
}
