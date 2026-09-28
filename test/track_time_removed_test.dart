import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/plan_requests/application/plan_request_providers.dart';
import 'package:time_app/features/plan_requests/presentation/plan_request_screens.dart';
import 'package:time_app/routing/app_router.dart';

/// Batch G item 8 (2026-09-27): Track Time is removed entirely, and its slot
/// in the bottom bar is the Request pillar; REQUEST PLAN moved off Plan.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('the Track Time feature and its rules are gone', () {
    expect(Directory('lib/features/time_tracking').existsSync(), isFalse);
    expect(read('firestore.rules'), isNot(contains('match /trackedTime/')));
    expect(read('lib/routing/app_router.dart'), isNot(contains('TrackScreen')));
  });

  test('the bar is Plan · Request · Stats · You', () {
    final shell = read('lib/features/home/presentation/home_shell.dart');
    final labels = RegExp(
      r"label: '(\w+)'",
    ).allMatches(shell).map((m) => m.group(1)).toList();
    expect(labels, ['Plan', 'Request', 'Stats', 'You']);
    // The Request pillar counts requests waiting on me.
    expect(
      shell,
      contains('badgeCount: ref.watch(incomingPlanRequestCountProvider)'),
    );
    expect(shell, isNot(contains("'Track")));
  });

  // 2026-09-27 (user-directed): the centre ⊕ voice button and its spoken-plan
  // flow are gone; voice-note alarms are unaffected.
  test('the centre voice button and speech-to-plan are removed', () {
    final shell = read('lib/features/home/presentation/home_shell.dart');
    expect(shell, isNot(contains('FloatingActionButton')));
    expect(shell, isNot(contains('_voicePlan')));
    expect(shell, isNot(contains('Track time')));
    expect(Directory('lib/features/voice').existsSync(), isFalse);
    expect(read('pubspec.yaml'), isNot(contains('speech_to_text')));
    expect(
      read('android/app/src/main/AndroidManifest.xml'),
      isNot(contains('RecognitionService')),
    );
    // Voice-note alarms still record audio.
    expect(
      read('android/app/src/main/AndroidManifest.xml'),
      contains('android.permission.RECORD_AUDIO'),
    );
    expect(Directory('lib/features/voice_notes').existsSync(), isTrue);
  });

  test('plan requests live at the Request pillar, not under Friends', () {
    expect(Routes.planRequests, Routes.requests);
    expect(Routes.newPlanRequest, '/requests/new');
    expect(Routes.fulfillPlanRequestFor('x'), '/requests/fulfill/x');
    final friends = read(
      'lib/features/social/presentation/friends_screen.dart',
    );
    expect(friends, isNot(contains("'Plan requests'")));
  });

  test('REQUEST PLAN left the Plan tab', () {
    final plan = read('lib/features/plan/presentation/plan_shell.dart');
    expect(plan, isNot(contains("'REQUEST PLAN'")));
    expect(plan, contains("label: const Text('PLAN')"));
  });

  testWidgets('the Request pillar has REQUEST PLAN at the bottom-left', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          incomingPlanRequestsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          outgoingPlanRequestsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const PlanRequestsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('REQUEST PLAN'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(
      scaffold.floatingActionButtonLocation,
      FloatingActionButtonLocation.startFloat,
    );
    expect(find.text('No open plan requests.'), findsOneWidget);
  });
}
