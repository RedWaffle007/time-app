import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/widgets/warning_panel.dart';
import 'package:time_app/features/applock/application/app_lock_controller.dart';
import 'package:time_app/features/applock/application/app_lock_providers.dart';
import 'package:time_app/features/applock/data/app_lock_store.dart';
import 'package:time_app/features/applock/data/device_auth.dart';
import 'package:time_app/features/applock/data/secure_window.dart';
import 'package:time_app/features/applock/presentation/app_lock_gate.dart';
import 'package:time_app/features/applock/presentation/app_lock_tile.dart';
import 'package:time_app/features/applock/presentation/lock_screen.dart';

/// **The lock is asserted here, not argued about.**
///
/// Two properties carry the whole feature and both are invisible in the code
/// unless you go looking: the 30s grace window (so glancing at another app
/// doesn't re-prompt) and the rule that an explicit task-kill locks immediately
/// regardless of it. A regression in either is silent — the app still runs, it
/// is just less locked than the user was told. Same standard as
/// `archive_isolation_test.dart`: prove it.
///
/// Pure Dart for the state machine, plus one widget test that pins the gate's
/// PLACEMENT — a lock covering only the home screen would pass every unit test
/// here and still leave the door open.
void main() {
  late _FakeStore store;
  late _FakeAuth auth;
  late _FakeSecureWindow secure;
  late DateTime clock;

  setUp(() {
    store = _FakeStore();
    auth = _FakeAuth();
    secure = _FakeSecureWindow();
    clock = DateTime.utc(2026, 7, 26, 9);
  });

  AppLockController build({bool enabled = true, Duration? grace}) {
    return AppLockController(
      store: store,
      auth: auth,
      secureWindow: secure,
      initiallyEnabled: enabled,
      now: () => clock,
      grace: grace ?? kAppLockGrace,
    );
  }

  /// A controller that is on and already past its lock screen — the state every
  /// grace-window test starts from.
  Future<AppLockController> unlocked({Duration? grace}) async {
    final c = build(grace: grace);
    expect(c.isLocked, isTrue, reason: 'a fresh process starts locked');
    await c.unlock();
    expect(c.isLocked, isFalse);
    return c;
  }

  group('the grace period', () {
    test('a return INSIDE the window does not re-lock', () async {
      final c = await unlocked();

      c.didBackground();
      clock = clock.add(const Duration(seconds: 29));
      c.didForeground();

      expect(c.isLocked, isFalse,
          reason: 'glancing at another app for 29s must not re-prompt');
    });

    test('a return AFTER the window locks', () async {
      final c = await unlocked();

      c.didBackground();
      clock = clock.add(const Duration(seconds: 31));
      c.didForeground();

      expect(c.isLocked, isTrue);
    });

    test('the boundary itself locks — the window is exclusive at 30s', () async {
      final c = await unlocked();

      c.didBackground();
      clock = clock.add(kAppLockGrace);
      c.didForeground();

      expect(c.isLocked, isTrue,
          reason: '>= grace, so exactly 30s is outside the window');
    });

    test('a bare resume with no backgrounding never locks', () async {
      final c = await unlocked();

      // The notification shade, a permission sheet: `resumed` with no preceding
      // `paused`. Locking here would throw people out of an app they are looking
      // at.
      clock = clock.add(const Duration(hours: 3));
      c.didForeground();

      expect(c.isLocked, isFalse);
    });

    test('the window is consumed — a second resume cannot re-use it', () async {
      final c = await unlocked();

      c.didBackground();
      clock = clock.add(const Duration(seconds: 5));
      c.didForeground();
      expect(c.isLocked, isFalse);

      // No new background. A stale `_leftAt` left behind here would lock the app
      // in the user's hands the next time anything triggered a resume.
      clock = clock.add(const Duration(hours: 1));
      c.didForeground();

      expect(c.isLocked, isFalse);
    });

    test("the OS prompt's own backgrounding does not open a window", () async {
      // local_auth backgrounds the app to show its dialog. If that counted as
      // leaving, every unlock would arm a grace window the user never asked for.
      final gate = Completer<bool>();
      auth.pending = gate;
      final c = build();

      final unlocking = c.unlock();
      await Future<void>.delayed(Duration.zero);
      c.didBackground(); // the OS dialog appearing
      gate.complete(true);
      await unlocking;

      expect(c.isLocked, isFalse);

      clock = clock.add(const Duration(hours: 1));
      c.didForeground();

      expect(c.isLocked, isFalse,
          reason: 'the prompt is not the user leaving the app');
    });
  });

  group('task-kill locks immediately', () {
    test('a fresh process starts LOCKED when the lock is on', () {
      expect(build(enabled: true).isLocked, isTrue,
          reason: 'the grace window lives in RAM, which a kill destroys');
    });

    test('a fresh process starts unlocked when the lock is off', () {
      expect(build(enabled: false).isLocked, isFalse);
    });

    test('detach locks now, however fresh the grace window is', () async {
      final c = await unlocked();

      c.didBackground();
      clock = clock.add(const Duration(seconds: 1));
      c.didDetach();

      expect(c.isLocked, isTrue);
    });

    test('a resume inside 30s cannot undo a detach', () async {
      final c = await unlocked();

      c.didBackground();
      c.didDetach();
      clock = clock.add(const Duration(seconds: 2));
      c.didForeground();

      expect(c.isLocked, isTrue,
          reason: 'a task-kill must never be cheaper than walking away');
    });

    test('detach on a disabled lock does nothing', () {
      final c = build(enabled: false);
      c.didDetach();
      expect(c.isLocked, isFalse);
    });
  });

  group('the toggle refuses on a device that cannot authenticate', () {
    test('turning it ON is declined, and explains why', () async {
      auth.canAuth = false;
      final c = build(enabled: false);

      final accepted = await c.setEnabled(true);

      expect(accepted, isFalse);
      expect(c.isEnabled, isFalse, reason: 'the switch must not move');
      expect(c.isLocked, isFalse, reason: 'and must not lock anyone out');
      expect(c.notice, isNotNull,
          reason: 'a refusal the user cannot see is a bug they will report as '
              '"the switch is broken"');
      expect(c.notice, contains('no screen lock'));
      expect(store.writes, isEmpty,
          reason: 'nothing may persist from a refused request');
      expect(secure.calls, isEmpty);
    });

    test('turning it ON succeeds when the device can', () async {
      final c = build(enabled: false);

      final accepted = await c.setEnabled(true);

      expect(accepted, isTrue);
      expect(c.isEnabled, isTrue);
      expect(store.writes, [true]);
      expect(secure.calls, [true],
          reason: 'FLAG_SECURE rides the same switch, not a second one');
      expect(c.isLocked, isFalse,
          reason: 'the user is holding the phone — do not prompt them now');
    });

    test('turning it OFF clears the setting and the window flag', () async {
      final c = await unlocked();

      await c.setEnabled(false);

      expect(c.isEnabled, isFalse);
      expect(c.isLocked, isFalse);
      expect(store.writes, [false]);
      expect(secure.calls, [false]);
    });

    test('the notice is one-shot', () async {
      auth.canAuth = false;
      final c = build(enabled: false);
      await c.setEnabled(true);

      expect(c.notice, isNotNull);
      c.consumeNotice();
      expect(c.notice, isNull);
    });
  });

  group('a lock that became unopenable turns itself off', () {
    test('unlock disables when the credential is gone, and says so', () async {
      // The user removed their screen lock while the app lock was on. Staying
      // locked here is a bricked app, and nobody could have reached this state
      // without entering the credential they were removing.
      final c = build();
      auth.canAuth = false;

      await c.unlock();

      expect(c.isEnabled, isFalse);
      expect(c.isLocked, isFalse);
      expect(c.notice, isNotNull);
      expect(c.notice, contains('turned off'));
      expect(store.writes, [false]);
      expect(secure.calls, [false]);
      expect(auth.prompts, 0, reason: 'no point prompting a device that cannot');
    });

    test('a cancelled or failed prompt stays locked, with no notice', () async {
      final c = build();
      auth.succeeds = false;

      await c.unlock();

      expect(c.isLocked, isTrue);
      expect(c.isEnabled, isTrue);
      expect(c.notice, isNull, reason: 'cancelling is not an error to explain');
    });

    test('unlock is a no-op when the lock is off', () async {
      final c = build(enabled: false);
      await c.unlock();
      expect(auth.prompts, 0);
    });

    test('concurrent unlocks raise only one prompt', () async {
      final gate = Completer<bool>();
      auth.pending = gate;
      final c = build();

      final first = c.unlock();
      final second = c.unlock();
      gate.complete(true);
      await Future.wait([first, second]);

      expect(auth.prompts, 1, reason: 'the second tap must not stack a dialog');
    });
  });

  group('a disabled lock is inert', () {
    test('no lifecycle sequence can lock it', () {
      final c = build(enabled: false);

      c.didBackground();
      clock = clock.add(const Duration(days: 1));
      c.didForeground();

      expect(c.isLocked, isFalse);
    });

    test('start() re-applies FLAG_SECURE to match the setting', () async {
      // Per-window and lost on process death, so it is re-applied every launch
      // rather than only when the toggle moves.
      await build(enabled: true).start();
      expect(secure.calls, [true]);

      secure.calls.clear();
      await build(enabled: false).start();
      expect(secure.calls, [false]);
    });
  });

  // -------------------------------------------------------------------------
  // Placement. The unit tests above would all pass with the gate mounted inside
  // HomeGate, where a pushed route or an open dialog sits ON TOP of it. Moving
  // the gate from `builder:` to `home:` turns the first test below red, which is
  // the point of it.
  //
  // Honest limit: what stops the tap is the opaque full-bleed LockScreen, and
  // that is what these assert. The gate's `IgnorePointer` and `ExcludeSemantics`
  // are defence-in-depth BEHIND that cover — removing either leaves these tests
  // green, so they are reasoned about, not pinned. Anyone making the lock screen
  // translucent is on their own here.
  // -------------------------------------------------------------------------
  group('the gate has no door', () {
    testWidgets('an open dialog and a pushed route are both behind the lock',
        (tester) async {
      var dialogTapped = false;
      // Zero grace: any real background/foreground round-trip locks, so the test
      // drives lifecycle rather than a clock.
      final controller = build(grace: Duration.zero);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLockInitiallyEnabledProvider.overrideWithValue(true),
            appLockControllerProvider.overrideWithValue(controller),
          ],
          child: MaterialApp(
            // EXACTLY the wiring in app.dart — above the Navigator, not in a route.
            builder: (context, child) =>
                AppLockGate(child: child ?? const SizedBox.shrink()),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: TextButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => AlertDialog(
                              content: TextButton(
                                onPressed: () => dialogTapped = true,
                                child: const Text('secret action'),
                              ),
                            ),
                          ),
                          child: const Text('open dialog'),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('push route'),
                ),
              ),
            ),
          ),
        ),
      );

      // The gate starts locked (fresh process, lock on). Clear it the way a user
      // would, then build up a stack behind it.
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsNothing,
          reason: 'the auto-prompt succeeded');

      await tester.tap(find.text('push route'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open dialog'));
      await tester.pumpAndSettle();
      expect(find.text('secret action'), findsOneWidget);

      // Now leave and come back — with the prompt failing, so it stays locked.
      auth.succeeds = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.byType(LockScreen), findsOneWidget);

      // THE ASSERTION. The dialog is still mounted — the gate overlays, it does
      // not replace, so the user's stack survives — but it cannot be touched.
      expect(find.text('secret action'), findsOneWidget,
          reason: 'the navigator stack must survive a lock');
      await tester.tap(find.text('secret action'), warnIfMissed: false);
      await tester.pump();
      expect(dialogTapped, isFalse,
          reason: 'a dialog above HomeGate but below the gate would be tappable '
              '— that is the door this placement closes');
    });

    testWidgets('an explicit task-kill locks even inside the grace window',
        (tester) async {
      final controller = build(grace: const Duration(minutes: 5));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLockInitiallyEnabledProvider.overrideWithValue(true),
            appLockControllerProvider.overrideWithValue(controller),
          ],
          child: MaterialApp(
            builder: (context, child) =>
                AppLockGate(child: child ?? const SizedBox.shrink()),
            home: const Scaffold(body: Text('schedule')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LockScreen), findsNothing);

      auth.succeeds = false;
      // A five-minute grace window is wide open, and `detached` still locks.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.byType(LockScreen), findsOneWidget);
    });

    testWidgets('`inactive` alone never locks', (tester) async {
      // The shade and system permission sheets fire `inactive`. Mapping it would
      // lock people out mid-task.
      final controller = build(grace: Duration.zero);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLockInitiallyEnabledProvider.overrideWithValue(true),
            appLockControllerProvider.overrideWithValue(controller),
          ],
          child: MaterialApp(
            builder: (context, child) =>
                AppLockGate(child: child ?? const SizedBox.shrink()),
            home: const Scaffold(body: Text('schedule')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      auth.succeeds = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.byType(LockScreen), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // The toggle. The controller returning `false` is not the feature — the user
  // SEEING why is.
  // -------------------------------------------------------------------------
  group('the refusal is shown, not just returned', () {
    testWidgets('a device with no biometric and no PIN sees the refusal',
        (tester) async {
      auth.canAuth = false;
      final controller = build(enabled: false);

      await tester.pumpWidget(_TileHarness(controller: controller));
      expect(find.byType(WarningPanel), findsNothing);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // The explanation is ON SCREEN, in the one panel recipe.
      expect(find.byType(WarningPanel), findsOneWidget);
      expect(
        find.textContaining('no screen lock or biometric set up'),
        findsOneWidget,
      );
      // And the switch did not move — no lock was turned on.
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(controller.isEnabled, isFalse);
    });

    testWidgets('a capable device turns the lock on with no panel',
        (tester) async {
      final controller = build(enabled: false);

      await tester.pumpWidget(_TileHarness(controller: controller));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(find.byType(WarningPanel), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(controller.isEnabled, isTrue);
    });

    testWidgets('the lock turning ITSELF off is explained too', (tester) async {
      // The user removed their screen lock while the app lock was on. The lock
      // disables itself on the next unlock attempt, and the tile is where that
      // is accounted for.
      final controller = build(enabled: true);
      auth.canAuth = false;
      await controller.unlock();

      await tester.pumpWidget(_TileHarness(controller: controller));
      await tester.pumpAndSettle();

      expect(find.byType(WarningPanel), findsOneWidget);
      expect(find.textContaining('App lock turned off'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });
  });
}

/// The edge case that matters most, rendered rather than asserted: a device with
/// no biometric and no device credential must get a toggle that REFUSES and
/// EXPLAINS. A controller returning `false` into a screen that drops it on the
/// floor is indistinguishable, to the user, from a broken switch.
class _TileHarness extends StatelessWidget {
  const _TileHarness({required this.controller});

  final AppLockController controller;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        appLockInitiallyEnabledProvider.overrideWithValue(false),
        appLockControllerProvider.overrideWithValue(controller),
      ],
      // The real theme: WarningPanel reads the `attention` ThemeExtension, so a
      // bare MaterialApp would throw rather than render the refusal.
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: AppLockTile()),
      ),
    );
  }
}

class _FakeStore implements AppLockStore {
  bool enabled = false;
  final writes = <bool>[];

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<void> setEnabled(bool value) async {
    enabled = value;
    writes.add(value);
  }
}

class _FakeAuth implements DeviceAuth {
  bool canAuth = true;
  bool succeeds = true;
  int prompts = 0;

  /// When set, [authenticate] blocks on this instead of returning immediately —
  /// used to hold the app "inside the OS prompt" and interleave lifecycle events.
  Completer<bool>? pending;

  @override
  Future<bool> canAuthenticate() async => canAuth;

  @override
  Future<bool> authenticate() {
    prompts++;
    final gate = pending;
    if (gate != null) return gate.future;
    return Future.value(succeeds);
  }
}

class _FakeSecureWindow implements SecureWindow {
  final calls = <bool>[];

  @override
  Future<void> setSecure(bool value) async => calls.add(value);
}
