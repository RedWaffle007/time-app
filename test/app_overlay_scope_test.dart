import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/widgets/app_overlay_scope.dart';

/// Hosts above the router (MaterialApp.builder) need an overlay of their own
/// (device report 2026-10-05: "No Overlay widget found" red screen).
void main() {
  Widget app({required bool scoped, String label = 'Screen'}) => MaterialApp(
    builder: (context, child) {
      final hosts = Stack(
        children: [
          child!,
          const Align(
            alignment: Alignment.topRight,
            child: Tooltip(message: 'Close', child: Text('above-router')),
          ),
        ],
      );
      return scoped ? AppOverlayScope(child: hosts) : hosts;
    },
    home: Scaffold(body: Center(child: Text(label))),
  );

  testWidgets('without it, a tooltip above the router is the red error '
      'screen (the bug)', (tester) async {
    await tester.pumpWidget(app(scoped: false));
    expect(tester.takeException(), isNotNull);
  });

  testWidgets('with it, a tooltip above the router works', (tester) async {
    await tester.pumpWidget(app(scoped: true));
    expect(tester.takeException(), isNull);
    await tester.longPress(find.text('above-router'));
    await tester.pumpAndSettle();
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('screens still get the router\'s dialogs, and the hosts keep '
      'their place on rebuild', (tester) async {
    await tester.pumpWidget(app(scoped: true));
    await tester.pumpWidget(app(scoped: true, label: 'Screen 2'));
    expect(find.text('Screen 2'), findsOneWidget);
    final screen = tester.element(find.text('Screen 2'));
    showDialog<void>(
      context: screen,
      builder: (_) => const AlertDialog(content: Text('A dialog')),
    );
    await tester.pumpAndSettle();
    expect(find.text('A dialog'), findsOneWidget);
    // The dialog opened on the app's navigator, so Back (a pop) closes it.
    Navigator.of(screen).pop();
    await tester.pumpAndSettle();
    expect(find.text('A dialog'), findsNothing);
  });
}
