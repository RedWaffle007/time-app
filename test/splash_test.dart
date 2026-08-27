import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:time_app/features/auth/application/auth_providers.dart';
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

  testWidgets('cold start: single-line MJQ SOFTWARE reveal, then fades to app',
      (tester) async {
    await tester.pumpWidget(_host());

    // The wordmark is present during the reveal, on one line, exactly as typed.
    final wordmark = find.text('MJQ SOFTWARE');
    expect(wordmark, findsOneWidget);
    expect(tester.widget<Text>(wordmark).maxLines, 1);

    // Let the intro + hold + outro run to completion.
    await tester.pump(const Duration(milliseconds: 3000)); // intro
    await tester.pump(const Duration(milliseconds: 600)); // outro
    await tester.pumpAndSettle();

    // Reveal gone, app shown.
    expect(find.text('MJQ SOFTWARE'), findsNothing);
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('warm path: once played in-process, a new overlay never reveals',
      (tester) async {
    // First overlay plays and completes → sets the process-scoped flag.
    await tester.pumpWidget(_host());
    await tester.pump(const Duration(milliseconds: 3000));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('MJQ SOFTWARE'), findsNothing);

    // A brand-new overlay (simulating a rebuild in the same live process) must
    // pass straight through to the child with no reveal on the very first frame.
    await tester.pumpWidget(_host());
    expect(find.text('MJQ SOFTWARE'), findsNothing);
    expect(find.text('APP'), findsOneWidget);
  });
}
