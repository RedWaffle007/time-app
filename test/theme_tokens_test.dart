import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_colors.dart';
import 'package:time_app/core/theme/app_text.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/core/theme/dataviz_tokens.dart';
import 'package:time_app/core/theme/status_style.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// Guards the design system's structural promises (UI-RULES.md). These are the
/// rules a screen can't be trusted to keep on its own.
void main() {
  for (final (name, theme) in [
    ('light', AppTheme.light),
    ('dark', AppTheme.dark),
  ]) {
    group(name, () {
      test('both ThemeExtensions are registered', () {
        // context.attention / context.codeDisplay use `!` — a missing extension
        // is a crash at first paint, not a compile error.
        expect(theme.extension<AppSemanticColors>(), isNotNull);
        expect(theme.extension<AppTypeExtension>(), isNotNull);
      });

      test('flat by default: cards carry a border, not a shadow', () {
        expect(theme.cardTheme.elevation, Elevations.flat);
        final shape = theme.cardTheme.shape! as RoundedRectangleBorder;
        expect(shape.side.color, theme.colorScheme.outlineVariant);
        expect(shape.borderRadius, Radii.md);
      });

      test('only nav, dialogs and sheets float', () {
        expect(theme.appBarTheme.elevation, Elevations.flat);
        expect(theme.appBarTheme.scrolledUnderElevation, Elevations.flat);
        expect(theme.floatingActionButtonTheme.elevation, Elevations.flat);
        expect(theme.navigationBarTheme.elevation, Elevations.nav);
        expect(theme.dialogTheme.elevation, Elevations.floating);
        expect(theme.bottomSheetTheme.elevation, Elevations.floating);
      });

      test('cards sit on a distinct tone from the scaffold', () {
        expect(theme.cardTheme.color, isNot(theme.scaffoldBackgroundColor));
      });

      testWidgets('every status and outcome badge renders', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Wrap(
                children: [
                  for (final s in ScheduleItemStatus.values)
                    Builder(builder: (c) => StatusBadge.status(s, c)),
                  for (final o in OutcomeResult.values)
                    Builder(builder: (c) => StatusBadge.outcome(o, c)),
                ],
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        for (final label in [
          'Pending',
          'Approved',
          'Rejected',
          'Cancelled',
          'Withdrawn',
          'Done',
          'Skipped',
        ]) {
          expect(find.text(label), findsOneWidget, reason: '$label badge');
        }
      });
    });
  }

  group('status doctrine (UI-RULES.md §2.3)', () {
    late BuildContext lightCtx;
    late BuildContext darkCtx;

    testWidgets('capture contexts', (tester) async {
      for (final (theme, assign) in [
        (AppTheme.light, (BuildContext c) => lightCtx = c),
        (AppTheme.dark, (BuildContext c) => darkCtx = c),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Builder(
              builder: (c) {
                assign(c);
                return const SizedBox();
              },
            ),
          ),
        );
      }

      for (final ctx in [lightCtx, darkCtx]) {
        final cs = Theme.of(ctx).colorScheme;

        // Red is rationed: it never appears as a status badge.
        for (final s in ScheduleItemStatus.values) {
          final st = statusStyle(ctx, s);
          expect(st.background, isNot(cs.error), reason: '$s fill');
          expect(st.foreground, isNot(cs.error), reason: '$s text');
          expect(st.background, isNot(cs.errorContainer), reason: '$s fill');
        }
        for (final o in OutcomeResult.values) {
          expect(outcomeStyle(ctx, o).background, isNot(cs.error));
        }

        // Rejected, Cancelled, Withdrawn and Skipped share ONE neutral
        // treatment — no dimmed variant (it measured 4.43:1 in dark).
        final neutrals = [
          statusStyle(ctx, ScheduleItemStatus.rejected),
          statusStyle(ctx, ScheduleItemStatus.cancelled),
          statusStyle(ctx, ScheduleItemStatus.withdrawn),
          outcomeStyle(ctx, OutcomeResult.skipped),
        ];
        for (final n in neutrals) {
          expect(n.treatment, StatusTreatment.neutral);
          expect(n.foreground, cs.onSurfaceVariant);
          // The border is the badge's only structure, so it must be `outline`.
          // `outlineVariant` measures 1.42:1 in dark — invisible.
          expect(n.border, cs.outline);
          expect(n.border, isNot(cs.outlineVariant));
        }

        // Pending is orange (attention); approved/done are green.
        expect(
          statusStyle(ctx, ScheduleItemStatus.pending).background,
          cs.tertiaryContainer,
        );
        expect(
          statusStyle(ctx, ScheduleItemStatus.approved).background,
          cs.primaryContainer,
        );
        // Done is the only solid badge in the system.
        final done = outcomeStyle(ctx, OutcomeResult.done);
        expect(done.treatment, StatusTreatment.solid);
        expect(done.background, cs.primary);
      }
    });
  });

  group('contrast floor (UI-RULES.md §7)', () {
    // §7 says every pairing is "verified by computation, not by eye". This is
    // that computation — a colour change that breaks AA fails here instead of
    // shipping and being caught on a phone, or not at all.
    for (final (name, sem, cs) in [
      ('light', AppSemanticColors.light, AppTheme.light.colorScheme),
      ('dark', AppSemanticColors.dark, AppTheme.dark.colorScheme),
    ]) {
      test('$name — attention text pairings clear AA on both fills', () {
        expect(
          _contrast(sem.onAttentionContainer, sem.attentionContainer),
          greaterThanOrEqualTo(4.5),
          reason: 'onAttentionContainer on the badge tint',
        );
        expect(
          _contrast(sem.onAttentionContainer, sem.attentionContainerStrong),
          greaterThanOrEqualTo(4.5),
          reason: 'onAttentionContainer on the warning panel fill',
        );
      });

      test(
        '$name — the panel fill is at least as strong as the badge tint',
        () {
          // The panel is the largest attention surface; it may never separate
          // from the card LESS than a badge does. In dark the two are the same
          // value, so this is an inclusive bound by design.
          expect(
            _contrast(sem.attentionContainerStrong, cs.surface),
            greaterThanOrEqualTo(_contrast(sem.attentionContainer, cs.surface)),
          );
        },
      );

      test('$name — Done stays the heaviest badge', () {
        // The solid win state must out-weigh every attention surface, or the
        // doctrine's "strongest badge" claim is false (UI-RULES.md §2.3).
        expect(
          _contrast(cs.primary, cs.surface),
          greaterThan(_contrast(sem.attentionContainerStrong, cs.surface)),
        );
      });
    }
  });

  group('semantic accent palette', () {
    for (final (name, theme) in [
      ('light', AppTheme.light),
      ('dark', AppTheme.dark),
    ]) {
      test('$name keeps meaningful accents distinct', () {
        final colors = theme.colorScheme;
        final categorical = colors.categorical;

        // Green is success/action; orange is attention; categorical marks give
        // schedule headers, Stats and profile surfaces semantic variety without
        // turning ordinary prose into a rainbow.
        expect(colors.primary, isNot(colors.tertiary));
        expect(categorical, hasLength(5));
        expect(categorical.toSet(), hasLength(5));
        expect(categorical, contains(colors.primary));
        expect(categorical[1], isNot(colors.primary)); // turquoise marker
        expect(categorical[2], isNot(colors.primary)); // gold marker
        expect(
          theme.extension<AppSemanticColors>()!.immersiveForeground,
          isNot(colors.onSurface),
          reason: 'immersive media has a dedicated scrim foreground',
        );
      });
    }
  });

  test('spacing stays on the 4pt grid', () {
    for (final v in [
      Space.xs,
      Space.sm,
      Space.md,
      Space.lg,
      Space.xl,
      Space.xxl,
      Space.xxxl,
    ]) {
      expect(v % 4, 0, reason: '$v is off-grid');
    }
    // 6, 10 and 20 were in the old UI and are banned.
    expect([
      Space.xs,
      Space.sm,
      Space.md,
      Space.lg,
      Space.xl,
    ], isNot(contains(6)));
  });
}

/// WCAG 2.x relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2.x contrast ratio, 1.0–21.0. Both colours must be fully opaque —
/// every value in `app_colors.dart` is.
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}
