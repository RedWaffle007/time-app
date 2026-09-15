import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/splash/data/splash_sound.dart';
import 'package:time_app/features/splash/presentation/splash_overlay.dart';

/// Signed-out auth so `_appReady()` short-circuits to ready immediately (no
/// profile stream to await) — the reveal plays its full timeline then fades.
Widget _host() => ProviderScope(
  overrides: [
    authStateProvider.overrideWith((ref) => Stream<User?>.value(null)),
  ],
  child: const Directionality(
    textDirection: TextDirection.ltr,
    child: SplashOverlay(child: Text('APP')),
  ),
);

void main() {
  setUp(SplashOverlay.resetForTest);

  testWidgets('cold start: single-line CHECKMATE reveal, then fades to app', (
    tester,
  ) async {
    await tester.pumpWidget(_host());

    // The wordmark is present during the reveal, on one line, exactly as typed.
    final wordmark = find.text('CHECKMATE');
    expect(wordmark, findsOneWidget);
    expect(tester.widget<Text>(wordmark).maxLines, 1);

    // The glow-heavy text is retained behind compositor-driven fade/scale
    // layers instead of being rebuilt by AnimatedBuilder on every tick.
    final lockupBoundary = find.byKey(SplashOverlay.lockupBoundaryKey);
    expect(lockupBoundary, findsOneWidget);
    final retainedLayer = tester.renderObject(lockupBoundary);
    expect(find.byType(AnimatedBuilder), findsNothing);
    expect(find.byType(FadeTransition), findsWidgets);
    expect(find.byType(ScaleTransition), findsNWidgets(2));
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.renderObject(lockupBoundary), same(retainedLayer));
    }

    // Let the intro + hold + outro run to completion.
    await tester.pump(const Duration(milliseconds: 2680)); // rest of intro
    await tester.pump(const Duration(milliseconds: 600)); // outro
    await tester.pumpAndSettle();

    // Reveal gone, app shown.
    expect(find.text('CHECKMATE'), findsNothing);
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets(
    'reveal blooms with the strike: ting fires at mount and the name is '
    'revealed within revealBudget, not a beat later',
    (tester) async {
      // Capture the native pendulum strike. It is fire-and-forget from
      // initState, so a mock handler is enough to prove it rang as the reveal
      // mounted (t=0), the instant the name must be glowing in.
      final strikes = <String>[];
      final channel = const MethodChannel(SplashSound.channelName);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        strikes.add(call.method);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      await tester.pumpWidget(_host());

      // The wordmark is mounted from the first frame; the black veil over it is
      // still opaque this instant — the reveal has only just begun.
      final veilFinder = find.byKey(SplashOverlay.revealVeilKey);
      expect(veilFinder, findsOneWidget);
      expect(find.text('CHECKMATE'), findsOneWidget);
      expect(
        tester.widget<FadeTransition>(veilFinder).opacity.value,
        greaterThan(0.5),
        reason: 'the reveal should start at t=0 fully veiled, then bloom open',
      );

      // By the budget after the ting, the veil must be essentially gone — the
      // name has glowed in WITH the strike. Under the old Interval(0.18, 0.52)
      // timing the veil is still fully opaque here, which is the regression this
      // guards against.
      await tester.pump(SplashOverlay.revealBudget);
      expect(
        tester.widget<FadeTransition>(veilFinder).opacity.value,
        lessThan(0.02),
        reason: 'the name must be revealed within revealBudget of the ting',
      );
      expect(
        strikes,
        contains('play'),
        reason: 'the pendulum strike must ring as the reveal mounts',
      );
    },
  );

  testWidgets('warm path: once played in-process, a new overlay never reveals', (
    tester,
  ) async {
    // First overlay plays and completes → sets the process-scoped flag.
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 3000));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('CHECKMATE'), findsNothing);

    // A brand-new overlay (simulating a rebuild in the same live process) must
    // pass straight through to the child with no reveal on the very first frame.
    await tester.pumpWidget(_host());
    expect(find.text('CHECKMATE'), findsNothing);
    expect(find.text('APP'), findsOneWidget);
  });
}
