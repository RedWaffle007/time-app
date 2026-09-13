import 'package:flutter/material.dart';

import 'app_colors.dart';

/// **Chart & dashboard colour roles — the ONE source every data-viz surface
/// pulls from** (the Stats dashboard, progress meters, sparklines, any future
/// chart). See UI-RULES.md §2.8 and §6.14.
///
/// Part of the Hearth visual direction's step-zero foundation (DECISIONS.md
/// "UI redesign — Hearth + Candidate A"). It is defined now and **used by
/// nothing yet**: establishing the source of truth before the Stats/Track
/// screens (migration slices S1–S2) consume it, so every chart references one
/// place rather than each inventing its own colours.
///
/// ## No new hex, no new contrast to verify
///
/// Every role maps onto an already-AA-verified colour in the scheme. Charts do
/// NOT get their own palette — the app is two hues, and a chart is not an
/// exception to that. Sage (`primary`) carries the positive / primary series and
/// every progress fill; terracotta (the attention family) carries the
/// attention / pending series; neutrals carry gridlines, axes and the empty
/// track. Adding charts introduces zero new pairings to check in UI-RULES.md §7.
///
/// ## The §2.7 firewall is preserved BY OMISSION — do not add a fill getter
///
/// There is deliberately **no `seriesAttentionFill`** returning
/// `tertiaryContainer`/`attentionContainer`. Two reasons, and both matter:
///
///   1. **Meaning.** Under §2.7 an orange *fill* is the one signal a user learns
///      to trust — "something is waiting on me". A chart bar filled orange for a
///      decorative "pending" series would spend that signal on decoration.
///   2. **Enforcement.** The §2.7 lint bans the literal `tertiaryContainer` /
///      `attentionContainer` in screens. A getter that returned one would
///      *launder* the fill past the regex — a firewall with a door in it. So the
///      attention series is a LINE/MARKER role ([seriesAttention] → `tertiary`,
///      the line-and-text role that is free everywhere), never a fill.
///
/// A chart that needs to show "waiting on you" draws it as a line, a dot, or a
/// label in [seriesAttention] — not a filled area. A filled area uses
/// [seriesPrimary] (sage), which §2.7 does not restrict.
extension AppDataVizColors on ColorScheme {
  /// Primary data series, progress fill, and the "completed / good" colour.
  /// Sage — action and affirmation (§2.1).
  Color get seriesPrimary => primary;

  /// The attention / pending series. Terracotta, as a **line or marker only** —
  /// never a filled area (see the class doc). This is the only chart use of the
  /// orange family.
  Color get seriesAttention => tertiary;

  /// A muted secondary / comparison series, when one series is not enough.
  /// Reuses the primary CONTAINER rather than introducing a third hue.
  Color get seriesMuted => primaryContainer;

  /// Gridlines and axis ticks — decorative structure, so the decorative
  /// hairline role, never the meaningful [outline].
  Color get chartGrid => outlineVariant;

  /// Axis labels, legends and tick text.
  Color get chartAxisLabel => onSurfaceVariant;

  /// The unfilled portion of a progress meter or ring. Matches the progress
  /// track already used by §6.7's linear bar.
  Color get progressTrack => surfaceContainerHigh;

  /// The categorical chart palette (DESIGN-NOTES §2): brand-green → turquoise →
  /// golden → violet → pink, chosen to stay distinct while series 1 follows the
  /// brand. Real chroma, reserved for meaning — multi-series charts and marks
  /// only, never chrome. Light/dark twins keep each series legible in both modes.
  List<Color> get categorical {
    final dark = brightness == Brightness.dark;
    return [
      primary,
      dark ? AppColors.darkTurquoise : AppColors.lightTurquoise,
      dark ? AppColors.darkGolden : AppColors.lightGolden,
      dark ? AppColors.darkViolet : AppColors.lightViolet,
      dark ? AppColors.darkPink : AppColors.lightPink,
    ];
  }

  /// A stable categorical accent for a named structural element such as a
  /// section heading or KPI tile. The label hash avoids positional colours
  /// changing when neighbouring content is inserted.
  Color categoricalAccentFor(String label) {
    var hash = 0;
    for (final codeUnit in label.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7fffffff;
    }
    return categorical[hash % categorical.length];
  }
}
