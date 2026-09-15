import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/widgets/time_backdrop.dart';

void main() {
  testWidgets(
    'the app-wide backdrop painter survives You, builder and modal navigation',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          // Mirrors TimeApp's builder: the backdrop wraps the Navigator rather
          // than being a page inside it, so pushed routes cannot cover/recreate
          // the pattern layer.
          builder: (context, child) => TimeBackdrop(
            key: TimeBackdrop.backdropKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const _Destination('You destination'),
                      ),
                    ),
                    child: const Text('Open You destination'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const _Destination('Schedule Builder'),
                      ),
                    ),
                    child: const Text('Open Schedule Builder'),
                  ),
                  TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => const SizedBox(
                        height: 120,
                        child: Center(child: Text('Create modal')),
                      ),
                    ),
                    child: const Text('Open modal'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final painter = tester
          .widget<CustomPaint>(find.byKey(TimeBackdrop.painterKey))
          .painter;

      await tester.tap(find.text('Open You destination'));
      await tester.pump();
      await _expectStablePainter(tester, painter);
      await tester.pump(const Duration(seconds: 1));
      await _expectStablePainter(tester, painter);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Schedule Builder'));
      await tester.pump();
      await _expectStablePainter(tester, painter);
      await tester.pump(const Duration(seconds: 1));
      await _expectStablePainter(tester, painter);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open modal'));
      await tester.pump();
      await _expectStablePainter(tester, painter);
      await tester.pump(const Duration(seconds: 1));
      await _expectStablePainter(tester, painter);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _expectStablePainter(
  WidgetTester tester,
  CustomPainter? painter,
) async {
  expect(find.byKey(TimeBackdrop.backdropKey), findsOneWidget);
  expect(find.byType(RepaintBoundary), findsWidgets);
  expect(
    tester.widget<CustomPaint>(find.byKey(TimeBackdrop.painterKey)).painter,
    same(painter),
  );
}

class _Destination extends StatelessWidget {
  const _Destination(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: const SizedBox.expand(),
  );
}
