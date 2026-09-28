import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_colors.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';

/// 2026-09-28 (DECISIONS.md "Bottom bar + phone nav bar match the screen"):
/// the pillar bar and the phone's own navigation bar take the screen's
/// background colour — near-white in light, near-black in dark — flat,
/// untinted, like Instagram.
void main() {
  for (final (name, theme, background) in [
    ('light', AppTheme.light, AppColors.lightBackground),
    ('dark', AppTheme.dark, AppColors.darkBackground),
  ]) {
    test('$name: the bar theme is the screen colour, flat, untinted', () {
      final bar = theme.bottomAppBarTheme;
      expect(bar.color, background);
      expect(bar.elevation, Elevations.flat);
      expect(bar.surfaceTintColor, Colors.transparent);
      expect(
        theme.extension<AppSemanticColors>()!.chromeBackground,
        background,
      );
    });

    testWidgets('$name: a BottomAppBar renders in the screen colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            bottomNavigationBar: BottomAppBar(child: SizedBox()),
          ),
        ),
      );
      final shape = tester.widget<PhysicalShape>(
        find.descendant(
          of: find.byType(BottomAppBar),
          matching: find.byType(PhysicalShape),
        ),
      );
      expect(shape.color, background);
      expect(shape.elevation, Elevations.flat);
    });
  }

  test('the phone nav bar: screen colour, readable icons, no scrim', () {
    final light = systemNavBarStyle(
      Brightness.light,
      AppColors.lightBackground,
    );
    expect(light.systemNavigationBarColor, AppColors.lightBackground);
    expect(light.systemNavigationBarIconBrightness, Brightness.dark);
    expect(light.systemNavigationBarContrastEnforced, isFalse);

    final dark = systemNavBarStyle(Brightness.dark, AppColors.darkBackground);
    expect(dark.systemNavigationBarColor, AppColors.darkBackground);
    expect(dark.systemNavigationBarIconBrightness, Brightness.light);
    expect(dark.systemNavigationBarContrastEnforced, isFalse);
  });

  test('wired: every route gets the nav-bar style; the shell draws no own '
      'colour and has a hairline top', () {
    final app = File('lib/app.dart').readAsStringSync();
    expect(app, contains('AnnotatedRegion<SystemUiOverlayStyle>'));
    expect(app, contains('systemNavBarStyle('));
    final shell = File(
      'lib/features/home/presentation/home_shell.dart',
    ).readAsStringSync();
    final bar = shell.substring(shell.indexOf('bottomNavigationBar:'));
    expect(bar.substring(0, 700), contains('Sizes.hairline'));
    expect(bar.substring(0, 700), isNot(contains('colors.surface')));
    expect(bar.substring(0, 700), isNot(contains('Elevations.nav')));
    // Keep the import honest.
    expect(SystemUiOverlayStyle.light, isNotNull);
  });
}
