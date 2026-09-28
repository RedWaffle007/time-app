import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/applock/application/app_lock_providers.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/settings/data/feedback_launcher.dart';
import 'package:time_app/features/settings/presentation/settings_screen.dart';

/// Settings → Send feedback (2026-09-28): opens the email app on a prefilled
/// message to the developer; with no email app, shows the address to copy.

class _Launcher implements FeedbackLauncher {
  _Launcher({required this.opens});

  final bool opens;
  final composed = <Map<String, String>>[];

  @override
  Future<bool> compose({
    required String to,
    required String subject,
    required String body,
  }) async {
    composed.add({'to': to, 'subject': subject, 'body': body});
    return opens;
  }
}

void main() {
  const me = UserProfile(
    uid: 'me',
    name: 'Test Planner',
    homeTimezone: 'Etc/UTC',
  );

  Future<_Launcher> pump(WidgetTester tester, {required bool opens}) async {
    tester.view.physicalSize = const Size(400 * 3, 2400 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final launcher = _Launcher(opens: opens);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          profileProvider.overrideWith((ref) => Stream.value(me)),
          appLockInitiallyEnabledProvider.overrideWithValue(false),
          feedbackLauncherProvider.overrideWithValue(launcher),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return launcher;
  }

  test('feedback uses the developer address and Mind Time subject', () {
    expect(kFeedbackAddress, 'mjqsoftware.inc@gmail.com');
    expect(kFeedbackSubject, 'Mind Time feedback');
  });

  testWidgets('Send feedback sits near the bottom of Settings', (tester) async {
    await pump(tester, opens: true);
    expect(find.text('Send feedback'), findsOneWidget);
    expect(
      find.text(
        'Ideas, bugs or anything else. It goes straight to the developer.',
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('Send feedback')).dy,
      greaterThan(tester.getTopLeft(find.text('How this app works')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Send feedback')).dy,
      lessThan(tester.getTopLeft(find.text('Sign out')).dy),
    );
  });

  testWidgets('it opens the email app, prefilled', (tester) async {
    final launcher = await pump(tester, opens: true);
    await tester.tap(find.byKey(const ValueKey('send-feedback')));
    await tester.pumpAndSettle();
    expect(launcher.composed, [
      {
        'to': kFeedbackAddress,
        'subject': 'Mind Time feedback',
        'body': '',
      },
    ]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('no email app: the address is shown and can be copied', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(tester, opens: false);
    await tester.tap(find.byKey(const ValueKey('send-feedback')));
    await tester.pumpAndSettle();
    expect(find.textContaining(kFeedbackAddress), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('feedback-copy-address')));
    await tester.pumpAndSettle();
    expect(copied, kFeedbackAddress);
    expect(find.text('Address copied.'), findsOneWidget);
  });

  test('the native side opens email apps only', () {
    final activity = File(
      'android/app/src/main/kotlin/com/timeapp/time_app/MainActivity.kt',
    ).readAsStringSync();
    expect(activity, contains('"time_app/feedback"'));
    expect(activity, contains('Intent.ACTION_SENDTO'));
    expect(activity, contains('Uri.parse("mailto:")'));
    expect(activity, contains('ActivityNotFoundException'));
    expect(activity, isNot(contains('"version"')));
  });
}
