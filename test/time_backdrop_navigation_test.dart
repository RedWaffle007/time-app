import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/widgets/time_backdrop.dart';

void main() {
  for (final variant in <(String, ThemeData)>[
    ('light', AppTheme.light),
    ('dark', AppTheme.dark),
  ]) {
    testWidgets(
      '${variant.$1} backdrop pixels survive intermediate push and pop frames',
      (tester) async {
        addTearDown(tester.view.reset);
        tester.view
          ..physicalSize = const Size(360, 640)
          ..devicePixelRatio = 1;

        final navigatorKey = GlobalKey<NavigatorState>();
        const captureKey = ValueKey<String>('transition-capture');

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            theme: variant.$2.copyWith(platform: TargetPlatform.android),
            builder: (context, child) => RepaintBoundary(
              key: captureKey,
              // Mirrors TimeApp: one backdrop sits outside the Navigator.
              child: TimeBackdrop(
                key: TimeBackdrop.backdropKey,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        );

        final before = _capture(tester, captureKey);
        addTearDown(before.dispose);

        navigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: SizedBox.expand()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        await expectLater(
          find.byKey(captureKey),
          matchesReferenceImage(before),
        );

        await tester.pumpAndSettle();
        navigatorKey.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        await expectLater(
          find.byKey(captureKey),
          matchesReferenceImage(before),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

ui.Image _capture(WidgetTester tester, Key key) =>
    tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImageSync();
