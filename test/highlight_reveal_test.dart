import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/widgets/highlight_reveal.dart';

/// Device report 2026-09-28: from the Calendar, the tapped plan was outlined
/// but sometimes only peeking at the bottom edge, so the user had to scroll.
/// A reveal now counts as landed only where `ensureVisible` puts the card.
void main() {
  final key = GlobalKey();

  Future<ScrollController> pump(WidgetTester tester, int target) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: ListView.builder(
              controller: controller,
              itemCount: 40,
              itemBuilder: (_, i) => SizedBox(
                key: i == target ? key : null,
                height: 100,
                child: Text('card $i'),
              ),
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  testWidgets('a card peeking at the bottom edge has NOT landed', (
    tester,
  ) async {
    final controller = await pump(tester, 10);
    controller.jumpTo(410); // card 10 spans 1000–1100; only 10 px show
    await tester.pump();
    expect(isHighlightRevealed(key.currentContext!), isFalse);
  });

  testWidgets('ensureVisible at the shared alignment lands it', (tester) async {
    final controller = await pump(tester, 10);
    controller.jumpTo(410);
    await tester.pump();
    await Scrollable.ensureVisible(
      key.currentContext!,
      alignment: kHighlightAlignment,
    );
    await tester.pump();
    expect(isHighlightRevealed(key.currentContext!), isTrue);
  });

  testWidgets('a card at the list end counts once the list is at its end', (
    tester,
  ) async {
    final controller = await pump(tester, 39);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(isHighlightRevealed(key.currentContext!), isTrue);
  });

  testWidgets('a card at the top counts at the top', (tester) async {
    await pump(tester, 0);
    expect(isHighlightRevealed(key.currentContext!), isTrue);
  });
}
