import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/data/profile_repository.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/application/target_schedule_providers.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/presentation/group_plan_sheet.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// Group alarms after F2 (2026-09-26): no approval and no Emergency switch —
/// one alarm rings for every member who gave the planner either permission.

const _self = (uid: 'PLANNER', isSelf: true);
const _normalA = (uid: 'MEMBER_A', isSelf: false);
const _normalB = (uid: 'MEMBER_B', isSelf: false);

class _Repo implements ScheduleRepository {
  final calls = <List<String>>[];

  @override
  Future<
    ({
      List<({String uid, String itemId, bool isSelf})> sent,
      int skippedPast,
      int skippedOther,
    })
  >
  planForGroup({
    required String groupId,
    required String createdByUid,
    required List<({String uid, String timezone, bool isSelf})> targets,
    required String title,
    String? note,
    required DateTime wall,
  }) async {
    calls.add([for (final t in targets) t.uid]);
    return (
      sent: [
        for (final t in targets)
          (uid: t.uid, itemId: 'i-${t.uid}', isSelf: t.isSelf),
      ],
      skippedPast: 0,
      skippedOther: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Profiles implements ProfileRepository {
  @override
  Stream<UserProfile?> watchProfile(String uid) => Stream.value(
    UserProfile(uid: uid, name: 'Name $uid', homeTimezone: 'UTC'),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifier implements NotificationEventNotifier {
  final created = <String>[];

  @override
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async => created.add(targetUid);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(_Repo, _Notifier)> _open(
  WidgetTester tester, {
  List<({String uid, bool isSelf})> candidates = const [
    _self,
    _normalA,
    _normalB,
  ],
  ThemeData? theme,
  double width = 360,
}) async {
  tester.view.physicalSize = Size(width * 3, 900 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final repo = _Repo();
  final notifier = _Notifier();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUidProvider.overrideWithValue('PLANNER'),
        scheduleRepositoryProvider.overrideWithValue(repo),
        profileRepositoryProvider.overrideWithValue(_Profiles()),
        profileByUidProvider.overrideWith(
          (ref, uid) => Stream.value(
            UserProfile(uid: uid, name: 'Name $uid', homeTimezone: 'UTC'),
          ),
        ),
        targetScheduleProvider.overrideWith((ref, uid) => Stream.value([])),
        notificationEventNotifierProvider.overrideWithValue(notifier),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.light,
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showGroupPlanSheet(
                context,
                ref,
                groupId: 'group',
                groupName: 'Family',
                candidates: candidates,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return (repo, notifier);
}

Future<void> _fillAndSend(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).first, 'Evacuate');
  await tester.tap(find.text('Pick date'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Pick time'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Send to the group'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('sheet', () {
    testWidgets('there is no Emergency switch and no approval wording', (
      tester,
    ) async {
      await _open(tester);
      expect(find.byKey(const ValueKey('group-plan-emergency')), findsNothing);
      expect(find.textContaining('mergency'), findsNothing);
      expect(find.textContaining('approv'), findsNothing);
      expect(find.textContaining('Rings for 3 members'), findsOneWidget);
      expect(find.text('Send to the group'), findsOneWidget);
    });

    testWidgets('a send reaches every candidate and notifies the others', (
      tester,
    ) async {
      final (repo, notifier) = await _open(tester);
      await _fillAndSend(tester);
      expect(repo.calls.single.toSet(), {'PLANNER', 'MEMBER_A', 'MEMBER_B'});
      expect(notifier.created.toSet(), {'MEMBER_A', 'MEMBER_B'});
      expect(find.textContaining('Alarm set for 3 members'), findsOneWidget);
    });

    for (final theme in [AppTheme.light, AppTheme.dark]) {
      testWidgets('the sheet fits a 320 px phone (${theme.brightness})', (
        tester,
      ) async {
        await _open(tester, theme: theme, width: 320);
        expect(tester.takeException(), isNull);
      });
    }
  });

  test('the group screen merges both permissions into one list', () {
    final source = File(
      'lib/features/groups/presentation/group_detail_screen.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('(iPlanFor(m.uid) || emergencyUids.contains(m.uid))'),
    );
  });
}
