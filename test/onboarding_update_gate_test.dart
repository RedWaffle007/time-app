import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/platform/oem_profile.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/notifications/application/messaging_service.dart';
import 'package:time_app/features/notifications/data/fcm_token_repository.dart';
import 'package:time_app/features/onboarding/application/onboarding_providers.dart';
import 'package:time_app/features/onboarding/data/onboarding_store.dart';
import 'package:time_app/features/onboarding/presentation/onboarding_gate.dart';
import 'package:time_app/features/reminders/application/reminder_providers.dart';
import 'package:time_app/features/reminders/data/reminder_scheduler.dart';

/// 2026-10-02 (user-directed): after an update the permissions page opens
/// again only when a permission the app can check is missing.
class _Store implements OnboardingStore {
  _Store({required this.completed, required this.checked});

  bool completed;
  bool checked;
  var updateChecks = 0;

  @override
  Future<bool> isCompleted() async => completed;

  @override
  Future<void> markCompleted() async {
    completed = true;
    checked = true;
  }

  @override
  Future<bool> isCheckedForThisUpdate() async => checked;

  @override
  Future<void> markUpdateChecked() async {
    updateChecks++;
    checked = true;
  }

  @override
  Future<void> reset() async {}
}

ReminderPermissionState _state({
  bool notifications = true,
  bool autostart = false,
}) => ReminderPermissionState(
  notificationsEnabled: notifications,
  exactAlarmsAllowed: true,
  fullScreenIntentAllowed: true,
  autostartLikelyNeeded: autostart,
);

Future<void> _pump(
  WidgetTester tester,
  _Store store,
  ReminderPermissionState state,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        onboardingStoreProvider.overrideWithValue(store),
        reminderPermissionStateProvider.overrideWith((ref) async => state),
        oemProfileProvider.overrideWith((ref) async => oemProfileFor('Xiaomi')),
        fcmTokenRepositoryProvider.overrideWithValue(_Tokens()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const OnboardingGate(child: Text('APP')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('updated, everything granted: straight to the app, recorded', (
    tester,
  ) async {
    final store = _Store(completed: true, checked: false);
    await _pump(tester, store, _state(autostart: true));
    expect(find.text('APP'), findsOneWidget);
    expect(find.text('Reminders & permissions'), findsNothing);
    expect(store.updateChecks, 1);
  });

  testWidgets('updated, a permission missing: the page opens', (tester) async {
    final store = _Store(completed: true, checked: false);
    await _pump(tester, store, _state(notifications: false));
    expect(find.text('Reminders & permissions'), findsOneWidget);
    expect(find.text('APP'), findsNothing);
    expect(store.updateChecks, 0);
  });

  testWidgets('already checked for this build: never asks again', (
    tester,
  ) async {
    final store = _Store(completed: true, checked: true);
    await _pump(tester, store, _state(notifications: false));
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('a fresh install still runs the first-run flow', (tester) async {
    final store = _Store(completed: false, checked: false);
    await _pump(tester, store, _state(autostart: true));
    expect(find.text('Reminders & permissions'), findsOneWidget);
  });
}

class _Tokens implements FcmTokenRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
