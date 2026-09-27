import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/walkthrough/presentation/how_it_works_screen.dart';
import 'package:time_app/features/walkthrough/presentation/walkthrough_overlay.dart';

/// The tour's copy is the one piece with no plugins, keys or layout, so it is
/// the piece that can be pinned without a device. These assertions guard the
/// contract `HomeShell` relies on: exactly four steps, in spatial bottom-bar
/// order, each one short line.
void main() {
  test('covers exactly the four bar targets, in spatial order', () {
    expect(kWalkthroughStepCopy.map((s) => s.heading).toList(), [
      'Plan',
      'Request',
      'Stats',
      'You',
    ]);
  });

  test('every step has a non-empty, single-line body', () {
    for (final step in kWalkthroughStepCopy) {
      expect(step.body.trim(), isNotEmpty, reason: '${step.heading} body');
      expect(
        step.body,
        isNot(contains('\n')),
        reason: '${step.heading} body must be one line',
      );
    }
  });

  test('Plan names PLAN; Request (Track\'s old slot) names REQUEST PLAN', () {
    expect(kWalkthroughStepCopy[0].body, contains('Tap PLAN'));
    expect(kWalkthroughStepCopy[0].body, isNot(contains('＋')));
    expect(kWalkthroughStepCopy[1].body, contains('REQUEST PLAN'));
    for (final step in kWalkthroughStepCopy) {
      expect(step.body, isNot(contains('log time')), reason: step.heading);
      expect(step.body, isNot(contains('mic')), reason: step.heading);
    }
  });

  testWidgets('How this app works names the PLAN button', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: const HowItWorksScreen(),
        ),
      ),
    );

    expect(find.textContaining('Tap PLAN, bottom-left'), findsOneWidget);
    expect(
      find.textContaining('Tap the ＋ button, bottom-right, to plan'),
      findsNothing,
    );
  });

  testWidgets('the guide is short and has no retired rules (H5)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400 * 3, 3000 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: const HowItWorksScreen(),
        ),
      ),
    );
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('\n');
    // Friendship IS the permission; requests ask one friend for one time.
    for (final retired in [
      'permission to plan',
      'turn the permission off',
      'given permission',
      'fill a time window',
      'one or more',
      'Plan requests',
      // The centre ⊕ voice button was removed (2026-09-27).
      'Centre mic',
      'Say it out loud',
    ]) {
      expect(texts, isNot(contains(retired)), reason: retired);
    }
    for (final heading in [
      'The bottom bar',
      'How it works',
      'Where things are',
    ]) {
      expect(find.text(heading), findsOneWidget, reason: heading);
    }
    expect(find.text('Replay the guided tour'), findsOneWidget);
  });
}
