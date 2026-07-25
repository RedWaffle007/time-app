import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_colors.dart';
import 'package:time_app/core/theme/app_text.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/core/theme/status_style.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// Guards the design system's structural promises (UI-RULES.md). These are the
/// rules a screen can't be trusted to keep on its own.
void main() {
  for (final (name, theme) in [('light', AppTheme.light), ('dark', AppTheme.dark)]) {
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
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Wrap(children: [
              for (final s in ScheduleItemStatus.values)
                Builder(builder: (c) => StatusBadge.status(s, c)),
              for (final o in OutcomeResult.values)
                Builder(builder: (c) => StatusBadge.outcome(o, c)),
            ]),
          ),
        ));
        expect(tester.takeException(), isNull);
        for (final label in [
          'Pending', 'Approved', 'Rejected', 'Cancelled', 'Withdrawn',
          'Done', 'Skipped',
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
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Builder(builder: (c) {
            assign(c);
            return const SizedBox();
          }),
        ));
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
        expect(statusStyle(ctx, ScheduleItemStatus.pending).background,
            cs.tertiaryContainer);
        expect(statusStyle(ctx, ScheduleItemStatus.approved).background,
            cs.primaryContainer);
        // Done is the only solid badge in the system.
        final done = outcomeStyle(ctx, OutcomeResult.done);
        expect(done.treatment, StatusTreatment.solid);
        expect(done.background, cs.primary);
      }
    });
  });

  test('spacing stays on the 4pt grid', () {
    for (final v in [
      Space.xs, Space.sm, Space.md, Space.lg,
      Space.xl, Space.xxl, Space.xxxl,
    ]) {
      expect(v % 4, 0, reason: '$v is off-grid');
    }
    // 6, 10 and 20 were in the old UI and are banned.
    expect([Space.xs, Space.sm, Space.md, Space.lg, Space.xl],
        isNot(contains(6)));
  });
}
