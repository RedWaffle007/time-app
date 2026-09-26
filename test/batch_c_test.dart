import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/core/widgets/tab_body_inset.dart';
import 'package:time_app/features/notifications/data/foreground_push_presenter.dart';
import 'package:time_app/features/splash/application/launch_reveal_policy.dart';
import 'package:time_app/features/splash/application/startup_sound_providers.dart';
import 'package:time_app/features/splash/data/splash_sound.dart';
import 'package:time_app/features/splash/data/startup_sound_store.dart';
import 'package:time_app/features/splash/presentation/splash_overlay.dart';
import 'package:time_app/features/splash/presentation/startup_sound_tile.dart';

/// Batch C (2026-09-26): startup-sound toggle, tab gutter, and push taps that
/// must show the startup screen instead of ringing over nothing.

class _FakeStore implements StartupSoundStore {
  _FakeStore({this.fail = false});
  final bool fail;
  final writes = <bool>[];

  @override
  Future<bool> isEnabled() async => true;

  @override
  Future<void> setEnabled(bool value) async {
    if (fail) throw StateError('disk full');
    writes.add(value);
  }
}

List<String> _captureStrikes(WidgetTester tester) {
  final strikes = <String>[];
  const channel = MethodChannel(SplashSound.channelName);
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
  return strikes;
}

Widget _splash({bool playSound = true}) => Directionality(
  textDirection: TextDirection.ltr,
  child: SplashOverlay(playSound: playSound, child: const Text('APP')),
);

void main() {
  setUp(SplashOverlay.resetForTest);

  group('item 9 — which launches skip the startup screen', () {
    test('an alarm launch skips it', () {
      expect(launchSkipsReveal(alarmLaunch: true), isTrue);
    });

    test('a tapped local reminder (bare item id) skips it', () {
      expect(
        launchSkipsReveal(alarmLaunch: false, localPayload: 'item-1'),
        isTrue,
      );
    });

    test('every push tap keeps it — inactivity, outcome, reminders', () {
      for (final data in [
        {'type': 'inactivity', 'event': 'inactivity'},
        {'event': 'outcome', 'itemId': 'i', 'subtype': 'done'},
        {'event': 'approvalReminder', 'itemId': 'i'},
        {'event': 'friendRequest', 'fromUid': 'A', 'toUid': 'B'},
      ]) {
        expect(
          launchSkipsReveal(
            alarmLaunch: false,
            localPayload: encodePushTapPayload(data),
          ),
          isFalse,
          reason: '$data',
        );
      }
    });

    test('an ordinary launch keeps it', () {
      expect(launchSkipsReveal(alarmLaunch: false), isFalse);
      expect(launchSkipsReveal(alarmLaunch: false, localPayload: ''), isFalse);
    });

    test('an FCM tray tap no longer tears the reveal down', () {
      // Regression pin: `_handleTap` used to call `_dismissColdStartReveal()`,
      // which killed the startup screen after its ting had already played.
      final app = File('lib/app.dart').readAsStringSync();
      final start = app.indexOf('void _handleTap(RemoteMessage message)');
      final end = app.indexOf('\n  }', start);
      expect(start, greaterThan(0));
      expect(
        app.substring(start, end),
        isNot(contains('_dismissColdStartReveal')),
      );
    });

    testWidgets('a push launch plays the full reveal with its strike', (
      tester,
    ) async {
      final strikes = _captureStrikes(tester);
      await tester.pumpWidget(_splash());
      expect(strikes, ['play']);
      expect(find.text('CHECKMATE'), findsOneWidget);
      await tester.pump(SplashOverlay.introDuration);
      await tester.pump(SplashOverlay.outroDuration);
      await tester.pumpAndSettle();
      expect(find.text('APP'), findsOneWidget);
    });
  });

  group('item 7 — startup sound toggle', () {
    testWidgets('off: the reveal still shows, silently', (tester) async {
      final strikes = _captureStrikes(tester);
      await tester.pumpWidget(_splash(playSound: false));
      expect(find.text('CHECKMATE'), findsOneWidget);
      expect(strikes, isEmpty);
      await tester.pump(SplashOverlay.introDuration);
      await tester.pump(SplashOverlay.outroDuration);
      await tester.pumpAndSettle();
    });

    testWidgets('on (default): the strike plays once', (tester) async {
      final strikes = _captureStrikes(tester);
      await tester.pumpWidget(_splash());
      expect(strikes, ['play']);
      await tester.pump(SplashOverlay.introDuration);
      await tester.pump(SplashOverlay.outroDuration);
      await tester.pumpAndSettle();
    });

    test('the store defaults ON and persists a change', () async {
      SharedPreferences.setMockInitialValues({});
      const store = SharedPrefsStartupSoundStore();
      expect(await store.isEnabled(), isTrue);
      await store.setEnabled(false);
      expect(await store.isEnabled(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SharedPrefsStartupSoundStore.key), isFalse);
    });

    test('the controller starts from the pre-runApp value', () {
      final off = ProviderContainer(
        overrides: [
          startupSoundInitiallyEnabledProvider.overrideWithValue(false),
        ],
      );
      addTearDown(off.dispose);
      expect(off.read(startupSoundEnabledProvider), isFalse);

      final unset = ProviderContainer();
      addTearDown(unset.dispose);
      expect(unset.read(startupSoundEnabledProvider), isTrue);
    });

    test('a change is persisted; a failed write reverts the switch', () async {
      final store = _FakeStore();
      final ok = ProviderContainer(
        overrides: [startupSoundStoreProvider.overrideWithValue(store)],
      );
      addTearDown(ok.dispose);
      await ok.read(startupSoundEnabledProvider.notifier).setEnabled(false);
      expect(ok.read(startupSoundEnabledProvider), isFalse);
      expect(store.writes, [false]);

      final broken = ProviderContainer(
        overrides: [
          startupSoundStoreProvider.overrideWithValue(_FakeStore(fail: true)),
        ],
      );
      addTearDown(broken.dispose);
      await broken.read(startupSoundEnabledProvider.notifier).setEnabled(false);
      expect(broken.read(startupSoundEnabledProvider), isTrue);
    });

    testWidgets('the tile flips the setting and says alarms still ring', (
      tester,
    ) async {
      final store = _FakeStore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [startupSoundStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(body: StartupSoundTile()),
          ),
        ),
      );
      expect(find.text('Startup sound'), findsOneWidget);
      expect(find.textContaining('Alarms always ring'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(store.writes, [false]);
    });

    test('the setting never touches alarm audio', () {
      // AlarmSoundService is native and owns alarm playback; only the splash
      // reads this setting.
      final users = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => f.readAsStringSync().contains('startupSoundEnabled'))
          .map((f) => f.path.replaceAll(r'\', '/'))
          .toSet();
      expect(users, {
        'lib/app.dart',
        'lib/main.dart',
        'lib/features/splash/application/startup_sound_providers.dart',
        'lib/features/splash/presentation/startup_sound_tile.dart',
      });
    });

    test('main() reads the setting before runApp', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(
        main.indexOf('_readStartupSoundSetting()'),
        lessThan(main.indexOf('runApp(')),
      );
      expect(main, contains('startupSoundInitiallyEnabledProvider'));
    });
  });

  group('item 8 — tab gutter', () {
    testWidgets('TabBodyInset applies the one gutter token', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: TabBodyInset(child: SizedBox.expand()),
        ),
      );
      final padding = tester.widget<Padding>(find.byType(Padding));
      expect(padding.padding, Space.tabBodyInset);
      expect(Space.tabBodyInset.left, Space.sm);
      expect(
        Space.tabBodyInset.right,
        Space.tabBodyInset.left,
        reason: 'symmetric, so cards stay centred',
      );
      expect(Space.tabBodyInset.top, 0);
    });

    test('every main-tab body sits in the gutter', () {
      for (final path in [
        'lib/features/plan/presentation/plan_shell.dart',
        'lib/features/time_tracking/presentation/track_screen.dart',
        'lib/features/stats/presentation/stats_screen.dart',
        'lib/features/home/presentation/you_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          RegExp(r'body:\s*TabBodyInset\(').hasMatch(source),
          isTrue,
          reason: '$path must wrap its body in TabBodyInset',
        );
      }
    });
  });

  group('inactivity delivery — its own channel', () {
    test(
      'inactivity pushes use the nudge channel; others the activity one',
      () {
        expect(
          channelIdForPush({'type': 'inactivity', 'event': 'inactivity'}),
          kNudgeChannelId,
        );
        expect(
          channelIdForPush({'event': 'outcome'}),
          kPlannerActivityChannelId,
        );
        expect(
          channelIdForPush({'event': 'approvalReminder'}),
          kPlannerActivityChannelId,
        );
      },
    );

    test('the Worker names the same nudge channel', () {
      final worker = File('worker/src/inactivity.js').readAsStringSync();
      expect(worker, contains("NUDGE_CHANNEL_ID = '$kNudgeChannelId'"));
    });

    test('a foreground inactivity push posts on the nudge channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'areNotificationsEnabled') return true;
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });

      await ForegroundPushPresenter(FlutterLocalNotificationsPlugin()).show(
        title: 'Make time for what matters',
        body: 'Body',
        data: {'type': 'inactivity', 'event': 'inactivity'},
      );
      final show = calls.singleWhere((c) => c.method == 'show');
      expect(
        ((show.arguments as Map)['platformSpecifics'] as Map)['channelId'],
        kNudgeChannelId,
      );
    });
  });
}
