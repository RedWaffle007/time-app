import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/app.dart';

/// **The back button, asserted instead of hand-run.**
///
/// The `PopScope` in `home_shell.dart` shipped broken and no test noticed: on a
/// fresh launch, Back at a tab root exited the app silently, because a branch
/// navigator's `canHandlePop: false` overwrote the shell's `true` and Android
/// then finished the activity without ever calling into Dart. The whole defect
/// lives in a single boolean sent over a platform channel, which is invisible
/// in the widget tree and invisible on screen — exactly the kind of thing a
/// device pass catches late and a test catches instantly.
///
/// So these tests watch the channel. [forceFrameworkHandlesBack] — the real
/// production handler from `app.dart` — is installed on a router built to the
/// same *shape* as the app's: a `StatefulShellRoute.indexedStack` with three
/// branches under a shell that owns the `PopScope`. It is not the real router
/// (that one reaches for Firebase in `redirect`); it is the arrangement that
/// produces the bug, which is what has to stay fixed.
void main() {
  /// Every `SystemChannels.platform` call, in order, as `method=arguments`.
  late List<String> platformCalls;

  /// Set by the shell's PopScope — proves Back actually reached Dart.
  late List<String> popScopeCalls;

  String? lastBackFlag() => platformCalls
      .where((c) => c.startsWith('SystemNavigator.setFrameworkHandlesBack='))
      .lastOrNull
      ?.split('=')
      .last;

  setUp(() {
    platformCalls = [];
    popScopeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add('${call.method}=${call.arguments}');
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// The flag is Android-only (`SystemNavigator.setFrameworkHandlesBack` returns
  /// early on every other platform), so the override is mandatory, not
  /// incidental. It is reset inside the test body rather than in `tearDown`
  /// because the framework's debug-var invariant check runs before `tearDown`.
  void onAndroid() =>
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
  void restorePlatform() => debugDefaultTargetPlatformOverride = null;

  /// The app's routing shape in miniature: three branches of an indexed-stack
  /// shell, the `PopScope(canPop: false)` on the shell (so it registers on the
  /// ROOT navigator's route, as in `home_shell.dart`), plus a top-level
  /// `/auth` that is deliberately outside the shell and has nothing to pop.
  GoRouter buildRouter() => GoRouter(
        initialLocation: '/groups',
        routes: [
          GoRoute(path: '/auth', builder: (_, _) => const Text('auth')),
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) => PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) =>
                  popScopeCalls.add('handleBack didPop=$didPop'),
              child: Scaffold(body: shell),
            ),
            branches: [
              StatefulShellBranch(routes: [
                GoRoute(path: '/groups', builder: (_, _) => const Text('g')),
              ]),
              StatefulShellBranch(routes: [
                GoRoute(path: '/outcome', builder: (_, _) => const Text('o')),
              ]),
              StatefulShellBranch(routes: [
                GoRoute(path: '/activity', builder: (_, _) => const Text('a')),
              ]),
            ],
          ),
        ],
      );

  /// Launch, with the lifecycle resumed BEFORE the first frame — which is the
  /// state a real launch is in, and which matters: both this handler and the
  /// framework's default one no-op while the lifecycle is still null.
  Future<GoRouter> launch(
    WidgetTester tester, {
    required bool withFix,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final router = buildRouter();
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: router,
      onNavigationNotification: withFix ? forceFrameworkHandlesBack : null,
    ));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('the framework handles Back from the very first frame',
      (tester) async {
    onAndroid();
    await launch(tester, withFix: true);

    // THE regression assertion. `false` here is the shipped defect: Android
    // finishes the activity itself and home_shell's _handleBack never runs.
    expect(lastBackFlag(), 'true',
        reason: 'a fresh launch at a tab root must report that Dart handles Back');
    restorePlatform();
  });

  testWidgets('Back at a tab root reaches the shell instead of exiting',
      (tester) async {
    onAndroid();
    await launch(tester, withFix: true);
    platformCalls.clear();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(popScopeCalls, ['handleBack didPop=false'],
        reason: "the shell's PopScope must be the one to decide what Back means");
    expect(platformCalls, isNot(contains('SystemNavigator.pop=null')),
        reason: 'the first Back at a tab root must not exit the app');
    restorePlatform();
  });

  testWidgets('/auth still exits on the first Back', (tester) async {
    onAndroid();
    final router = await launch(tester, withFix: true);
    router.go('/auth');
    await tester.pumpAndSettle();
    expect(find.text('auth'), findsOneWidget);
    platformCalls.clear();
    popScopeCalls.clear();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // Forcing the flag true only routes Back through Dart; it promises nothing.
    // With no PopScope and nothing to pop, handlePopRoute falls all the way
    // through to SystemNavigator.pop and the app closes, exactly as before.
    expect(popScopeCalls, isEmpty);
    expect(platformCalls, contains('SystemNavigator.pop=null'));
    restorePlatform();
  });

  testWidgets('nothing is sent to the engine before the app is attached',
      (tester) async {
    onAndroid();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await launch(tester, withFix: true);
    // launch() resumes first, so re-detach and force one more notification.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    platformCalls.clear();
    forceFrameworkHandlesBack(const NavigationNotification(canHandlePop: false));

    expect(platformCalls, isEmpty);
    restorePlatform();
  });

  testWidgets(
      'CANARY: without the handler a branch navigator still wins the flag',
      (tester) async {
    onAndroid();
    await launch(tester, withFix: false);

    // This documents the underlying framework behaviour the fix works around:
    // shell `true` dispatched, then a tab-root branch navigator's `false` last.
    // If this ever starts failing, Flutter changed how NavigationNotification
    // resolves under a shell route — re-read forceFrameworkHandlesBack and
    // check whether it is still needed, rather than "fixing" this test.
    expect(lastBackFlag(), 'false',
        reason: 'the default handler is last-writer-wins and the last writer '
            'is a branch navigator at its tab root');
    restorePlatform();
  });
}
