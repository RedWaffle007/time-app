import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/data/profile_repository.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/notifications/application/group_plan_reporter.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/presentation/group_plan_sheet.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// Group alarms after F2 (2026-09-26): no approval and no Emergency switch —
/// one alarm rings for every member who gave the planner either permission.

const _self = (uid: 'PLANNER', isSelf: true);
const _normalA = (uid: 'MEMBER_A', isSelf: false);
const _normalB = (uid: 'MEMBER_B', isSelf: false);

class _Repo implements ScheduleRepository {
  _Repo({this.busy = const {}});

  /// Members whose minute is already taken (item 4): no plan is set for them.
  final Set<String> busy;
  final calls = <List<String>>[];

  @override
  Future<
    ({
      List<({String uid, String itemId, bool isSelf})> sent,
      int skippedPast,
      int skippedOther,
      List<({String uid, DateTime instantUtc})> failed,
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
          if (!busy.contains(t.uid))
            (uid: t.uid, itemId: 'i-${t.uid}', isSelf: t.isSelf),
      ],
      skippedPast: 0,
      skippedOther: targets.where((t) => busy.contains(t.uid)).length,
      failed: [
        for (final t in targets)
          if (busy.contains(t.uid))
            (uid: t.uid, instantUtc: DateTime.utc(2030, 1, 1, 18)),
      ],
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

/// The Worker's verdict (item 4): which of the reported members really are
/// busy. Null = the Worker could not be reached.
class _Reporter implements GroupPlanReporter {
  _Reporter(this.verdict);

  final Set<String>? verdict;
  final reports = <({int setCount, List<String> uids})>[];

  @override
  Future<Set<String>?> reportBusy({
    required String groupId,
    required String title,
    required int setCount,
    required List<({String uid, DateTime instantUtc})> failed,
  }) async {
    reports.add((setCount: setCount, uids: [for (final f in failed) f.uid]));
    return verdict;
  }
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
  Map<String, String> zones = const {},
  Set<String> busy = const {},
  _Reporter? reporter,
}) async {
  tester.view.physicalSize = Size(width * 3, 900 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final repo = _Repo(busy: busy);
  final notifier = _Notifier();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUidProvider.overrideWithValue('PLANNER'),
        scheduleRepositoryProvider.overrideWithValue(repo),
        profileRepositoryProvider.overrideWithValue(_Profiles()),
        profileByUidProvider.overrideWith(
          (ref, uid) => Stream.value(
            UserProfile(
              uid: uid,
              name: 'Name $uid',
              homeTimezone: zones[uid] ?? 'UTC',
            ),
          ),
        ),
        groupPlanReporterProvider.overrideWithValue(reporter ?? _Reporter({})),
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

/// The first pick opens the member-times pop-up (item 4); close it.
Future<void> _continuePastTimes(WidgetTester tester) async {
  if (find.text('Continue').evaluate().isNotEmpty) {
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }
}

Future<void> _fillAndSend(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).first, 'Evacuate');
  await tester.tap(find.text('Pick date'));
  await tester.pumpAndSettle();
  await _continuePastTimes(tester);
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

    testWidgets('the first pick shows everyone\'s time now, one line each', (
      tester,
    ) async {
      await _open(
        tester,
        zones: const {
          'MEMBER_A': 'Asia/Kolkata',
          'MEMBER_B': 'America/Vancouver',
        },
      );
      await tester.tap(find.text('Pick date'));
      await tester.pumpAndSettle();
      expect(find.text("Everyone's time now"), findsOneWidget);
      for (final uid in ['PLANNER', 'MEMBER_A', 'MEMBER_B']) {
        expect(find.byKey(ValueKey('member-time-$uid')), findsOneWidget);
      }
      expect(find.textContaining('You: '), findsOneWidget);
      expect(find.textContaining('Name MEMBER_A: '), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      // …then the date picker itself.
      expect(find.text('OK'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // It does not open by itself again; the link reopens it.
      await tester.tap(find.text('Pick time'));
      await tester.pumpAndSettle();
      expect(find.text("Everyone's time now"), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('everyones-time')));
      await tester.pumpAndSettle();
      expect(find.text("Everyone's time now"), findsOneWidget);
    });

    testWidgets('busy members are skipped, verified, and named', (
      tester,
    ) async {
      final reporter = _Reporter({'MEMBER_B'});
      final (repo, notifier) = await _open(
        tester,
        busy: {'MEMBER_B'},
        reporter: reporter,
      );
      await _fillAndSend(tester);
      expect(notifier.created.toSet(), {'MEMBER_A'});
      expect(reporter.reports.single.uids, ['MEMBER_B']);
      expect(reporter.reports.single.setCount, 2);
      expect(
        find.text('Alarm set for 2 members. Busy at that time: Name MEMBER_B.'),
        findsOneWidget,
      );
    });

    testWidgets('a member the Worker does NOT confirm busy is not named', (
      tester,
    ) async {
      await _open(tester, busy: {'MEMBER_B'}, reporter: _Reporter({}));
      await _fillAndSend(tester);
      expect(find.textContaining('Busy at that time'), findsNothing);
      expect(find.text('Alarm set for 2 members · 1 skipped.'), findsOneWidget);
    });

    testWidgets('no report is made when everyone was set', (tester) async {
      final reporter = _Reporter({});
      await _open(tester, reporter: reporter);
      await _fillAndSend(tester);
      expect(reporter.reports, isEmpty);
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

  test(
    'the group screen offers EVERY member — no permission step (item 3)',
    () {
      final source = File(
        'lib/features/groups/presentation/group_detail_screen.dart',
      ).readAsStringSync();
      expect(
        source,
        contains('if (m.uid != myUid) (uid: m.uid, isSelf: false)'),
      );
      expect(source, isNot(contains('iPlanFor')));
      expect(source, isNot(contains('setPlannerGrant')));
      expect(source, isNot(contains('revokeMyPlannerGrant')));
    },
  );
}
