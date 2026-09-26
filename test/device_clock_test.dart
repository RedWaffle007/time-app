import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:time_app/core/format/datetime_format.dart';
import 'package:time_app/core/format/device_clock_localizations.dart';
import 'package:time_app/core/platform/device_clock.dart';
import 'package:time_app/core/platform/legacy_cleanup.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// F1 (2026-09-26): the phone's 12/24-hour setting wins over the language's
/// default — reported on a Nothing 4a whose 12-hour clock got a 24-hour picker.
/// F6: the removed chatbot leaves no model files and no mention behind.

Future<MaterialLocalizations> _base(Locale locale) =>
    GlobalMaterialLocalizations.delegate.load(locale);

const _afternoon = TimeOfDay(hour: 13, minute: 5);

Widget _host({
  required Locale locale,
  required bool? use24,
  required String Function(BuildContext) builder,
}) => MaterialApp(
  locale: locale,
  supportedLocales: const [
    Locale('en', 'GB'),
    Locale('en', 'US'),
    Locale('de'),
  ],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) =>
      DeviceClockScope(use24Hour: use24, child: child!),
  home: Builder(builder: (context) => Scaffold(body: Text(builder(context)))),
);

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await initializeDateFormatting();
  });

  group('localizations wrapper', () {
    test(
      'a 12-hour phone in a 24-hour-default language gets 12-hour',
      () async {
        for (final locale in [const Locale('en', 'GB'), const Locale('de')]) {
          final base = await _base(locale);
          expect(
            hourFormat(of: base.timeOfDayFormat()),
            isNot(HourFormat.h),
            reason: '$locale defaults to 24-hour — the bug\'s precondition',
          );
          final wrapped = DeviceClockMaterialLocalizations(
            base,
            use24Hour: false,
          );
          expect(hourFormat(of: wrapped.timeOfDayFormat()), HourFormat.h);
          expect(wrapped.formatHour(_afternoon), base.formatDecimal(1));
          expect(
            wrapped.formatTimeOfDay(_afternoon),
            '1:05 ${base.postMeridiemAbbreviation}',
          );
        }
      },
    );

    test(
      'a 24-hour phone in a 12-hour-default language gets 24-hour',
      () async {
        final base = await _base(const Locale('en', 'US'));
        expect(hourFormat(of: base.timeOfDayFormat()), HourFormat.h);
        final wrapped = DeviceClockMaterialLocalizations(base, use24Hour: true);
        expect(wrapped.timeOfDayFormat(), TimeOfDayFormat.HH_colon_mm);
        expect(wrapped.formatTimeOfDay(_afternoon), '13:05');
      },
    );

    test(
      'a 12-hour language on a 12-hour phone is left exactly as it was',
      () async {
        final base = await _base(const Locale('en', 'US'));
        final wrapped = DeviceClockMaterialLocalizations(
          base,
          use24Hour: false,
        );
        expect(wrapped.timeOfDayFormat(), base.timeOfDayFormat());
        expect(
          wrapped.formatTimeOfDay(_afternoon),
          base.formatTimeOfDay(_afternoon),
        );
      },
    );

    test('everything else is passed through unchanged', () async {
      final base = await _base(const Locale('de'));
      final wrapped = DeviceClockMaterialLocalizations(base, use24Hour: false);
      expect(wrapped.okButtonLabel, base.okButtonLabel);
      expect(wrapped.cancelButtonLabel, base.cancelButtonLabel);
      expect(
        wrapped.formatMediumDate(DateTime(2030, 3, 4)),
        base.formatMediumDate(DateTime(2030, 3, 4)),
      );
      expect(wrapped.anteMeridiemAbbreviation, base.anteMeridiemAbbreviation);
    });
  });

  group('the app-wide scope', () {
    testWidgets('the time picker follows a 12-hour phone in en-GB', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _host(
          locale: const Locale('en', 'GB'),
          use24: false,
          builder: (context) {
            ctx = context;
            return 'host';
          },
        ),
      );
      showTimePicker(context: ctx, initialTime: _afternoon);
      await tester.pumpAndSettle();
      final base = await _base(const Locale('en', 'GB'));
      expect(
        find.text(base.anteMeridiemAbbreviation),
        findsOneWidget,
        reason: 'a 12-hour picker shows the AM/PM toggle',
      );
    });

    testWidgets('the time picker follows a 24-hour phone in en-US', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _host(
          locale: const Locale('en', 'US'),
          use24: true,
          builder: (context) {
            ctx = context;
            return 'host';
          },
        ),
      );
      showTimePicker(context: ctx, initialTime: _afternoon);
      await tester.pumpAndSettle();
      expect(find.text('AM'), findsNothing);
      expect(find.text('PM'), findsNothing);
    });

    testWidgets('the format helper follows the phone, both ways', (
      tester,
    ) async {
      final utc = DateTime.utc(2030, 1, 1, 13, 5);
      await tester.pumpWidget(
        _host(
          locale: const Locale('en', 'GB'),
          use24: false,
          builder: (context) => formatInstantTime(context, utc, 'Etc/UTC'),
        ),
      );
      expect(find.textContaining('1:05'), findsOneWidget);
      expect(find.textContaining('13:05'), findsNothing);

      await tester.pumpWidget(
        _host(
          locale: const Locale('en', 'US'),
          use24: true,
          builder: (context) => formatInstantTime(context, utc, 'Etc/UTC'),
        ),
      );
      await tester.pump();
      expect(find.textContaining('13:05'), findsOneWidget);
    });

    testWidgets('an unknown setting changes nothing', (tester) async {
      await tester.pumpWidget(
        _host(
          locale: const Locale('en', 'US'),
          use24: null,
          builder: (context) => MediaQuery.of(context).alwaysUse24HourFormat
              ? 'forced'
              : 'flutter',
        ),
      );
      expect(find.text('flutter'), findsOneWidget);
    });
  });

  group('reading the phone', () {
    const channel = MethodChannel('time_app/clock');
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('the native answer, or null when there is none', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(await const DeviceClock().is24Hour(), isNull);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => true);
      expect(await const DeviceClock().is24Hour(), isTrue);
    });

    test('resume picks up a change made in Settings', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      var phone = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => phone);
      final container = ProviderContainer(
        overrides: [deviceClockInitialProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);
      expect(container.read(deviceUses24HourProvider), isFalse);
      phone = true;
      await container.read(deviceUses24HourProvider.notifier).refresh();
      expect(container.read(deviceUses24HourProvider), isTrue);
    });

    test('main reads it before the first frame; resume refreshes it', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(
        main.indexOf('DeviceClock().is24Hour()'),
        lessThan(main.indexOf('runApp(')),
      );
      final app = File('lib/app.dart').readAsStringSync();
      expect(app, contains('deviceUses24HourProvider.notifier).refresh()'));
      expect(app, contains('DeviceClockScope('));
    });
  });

  group('F6 — language practice is gone', () {
    test('the leftover model files are deleted, once', () async {
      final support = Directory.systemTemp.createTempSync('support');
      addTearDown(() => support.deleteSync(recursive: true));
      final model = Directory('${support.path}/$kLegacyChatbotModelFolder')
        ..createSync();
      File('${model.path}/model.onnx').writeAsBytesSync(List.filled(64, 1));
      File('${support.path}/voice-notes.keep').writeAsStringSync('mine');

      expect(await removeLegacyChatbotModel(support), isTrue);
      expect(model.existsSync(), isFalse);
      expect(File('${support.path}/voice-notes.keep').existsSync(), isTrue);
      expect(await removeLegacyChatbotModel(support), isFalse, reason: 'no-op');
    });

    test('no user-facing text mentions it any more', () {
      final hits = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) {
            final code = f
                .readAsLinesSync()
                .where((l) => !l.trimLeft().startsWith('//'))
                .join('\n');
            return RegExp(
              r"'[^'\n]*[Ll]anguage practice[^'\n]*'",
            ).hasMatch(code);
          })
          .map((f) => f.path)
          .toList();
      expect(hits, isEmpty);
    });
  });
}
