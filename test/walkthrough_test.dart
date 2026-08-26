import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/walkthrough/presentation/walkthrough_overlay.dart';

/// The tour's copy is the one piece with no plugins, keys or layout, so it is
/// the piece that can be pinned without a device. These assertions guard the
/// contract `HomeShell` relies on: exactly five steps, in spatial bottom-bar
/// order, each one short line.
void main() {
  test('covers exactly the five bar targets, in spatial order', () {
    expect(
      kWalkthroughStepCopy.map((s) => s.heading).toList(),
      ['Plan', 'Track', 'Speak to create', 'Stats', 'You'],
    );
  });

  test('every step has a non-empty, single-line body', () {
    for (final step in kWalkthroughStepCopy) {
      expect(step.body.trim(), isNotEmpty, reason: '${step.heading} body');
      expect(step.body, isNot(contains('\n')),
          reason: '${step.heading} body must be one line');
    }
  });
}
