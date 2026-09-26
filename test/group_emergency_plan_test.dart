import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/data/profile_repository.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/scheduling/application/group_plan_recipients.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/application/target_schedule_providers.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/group_plan_sheet.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// Item 15 (2026-09-26): an emergency group plan reaches only members who gave
/// the planner their own emergency permission, and says who it skips.

const _self = (uid: 'PLANNER', isSelf: true);
const _normalA = (uid: 'MEMBER_A', isSelf: false);
const _normalB = (uid: 'MEMBER_B', isSelf: false);

class _Repo implements ScheduleRepository {
  final calls = <(ItemTier, List<String>)>[];

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
    ItemTier tier = ItemTier.normal,
  }) async {
    calls.add((tier, [for (final t in targets) t.uid]));
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
  Set<String> emergencyUids = const {'MEMBER_A', 'MEMBER_C'},
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
                emergencyUids: emergencyUids,
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

Finder get _switch => find.byKey(const ValueKey('group-plan-emergency'));

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
  await tester.tap(find.byType(FilledButton));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('groupPlanRecipients', () {
    test('normal: everyone with a normal grant, nobody skipped', () {
      final r = groupPlanRecipients(
        candidates: const [_self, _normalA, _normalB],
        emergencyUids: const {'MEMBER_A'},
        emergency: false,
      );
      expect(r.recipients, const [_self, _normalA, _normalB]);
      expect(r.skippedUids, isEmpty);
    });

    test('emergency: self + emergency-granted members; the rest skipped', () {
      final r = groupPlanRecipients(
        candidates: const [_self, _normalA, _normalB],
        emergencyUids: const {'MEMBER_A', 'MEMBER_C'},
        emergency: true,
      );
      expect(r.recipients.map((c) => c.uid), [
        'PLANNER',
        'MEMBER_A',
        'MEMBER_C',
      ]);
      expect(r.recipients.where((c) => c.isSelf).map((c) => c.uid), [
        'PLANNER',
      ]);
      expect(r.skippedUids, ['MEMBER_B']);
    });

    test('an emergency-only member (no normal grant) is reachable', () {
      final r = groupPlanRecipients(
        candidates: const [_self],
        emergencyUids: const {'MEMBER_C'},
        emergency: true,
      );
      expect(r.recipients.map((c) => c.uid), ['PLANNER', 'MEMBER_C']);
      expect(r.skippedUids, isEmpty);
    });

    test('self in emergencyUids is never duplicated', () {
      final r = groupPlanRecipients(
        candidates: const [_self],
        emergencyUids: const {'PLANNER', 'MEMBER_A'},
        emergency: true,
      );
      expect(r.recipients.map((c) => c.uid), ['PLANNER', 'MEMBER_A']);
    });

    test(
      'never silently downgrades: nobody gets a normal copy in emergency',
      () {
        final r = groupPlanRecipients(
          candidates: const [_self, _normalA, _normalB],
          emergencyUids: const {},
          emergency: true,
        );
        expect(r.recipients.map((c) => c.uid), ['PLANNER']);
        expect(r.skippedUids, ['MEMBER_A', 'MEMBER_B']);
      },
    );
  });

  group('sheet', () {
    testWidgets('no emergency permission → no Emergency switch', (
      tester,
    ) async {
      await _open(tester, emergencyUids: const {});
      expect(_switch, findsNothing);
      expect(find.text('Plan for the group'), findsOneWidget);
    });

    testWidgets('switching Emergency on names who will be skipped', (
      tester,
    ) async {
      await _open(tester);
      expect(_switch, findsOneWidget);
      expect(find.byKey(const ValueKey('group-plan-skipped')), findsNothing);

      await tester.tap(_switch);
      await tester.pumpAndSettle();
      expect(
        find.text("Won't reach Name MEMBER_B — no emergency permission."),
        findsOneWidget,
      );
      expect(find.text('Plan emergency for the group'), findsOneWidget);
      expect(find.textContaining('skips approval'), findsOneWidget);
    });

    testWidgets(
      'an emergency send uses the emergency tier and its recipients',
      (tester) async {
        final (repo, notifier) = await _open(tester);
        await tester.tap(_switch);
        await tester.pumpAndSettle();
        await _fillAndSend(tester);

        expect(repo.calls, hasLength(1));
        final (tier, uids) = repo.calls.single;
        expect(tier, ItemTier.emergency);
        expect(uids.toSet(), {'PLANNER', 'MEMBER_A', 'MEMBER_C'});
        expect(uids, isNot(contains('MEMBER_B')));
        // Only the others are notified; the planner's own copy is not.
        expect(notifier.created.toSet(), {'MEMBER_A', 'MEMBER_C'});
      },
    );

    testWidgets('a normal send is unchanged', (tester) async {
      final (repo, _) = await _open(tester);
      await _fillAndSend(tester);
      final (tier, uids) = repo.calls.single;
      expect(tier, ItemTier.normal);
      expect(uids.toSet(), {'PLANNER', 'MEMBER_A', 'MEMBER_B'});
    });

    for (final theme in [AppTheme.light, AppTheme.dark]) {
      testWidgets('emergency sheet fits a 320 px phone (${theme.brightness})', (
        tester,
      ) async {
        await _open(tester, theme: theme, width: 320);
        await tester.tap(_switch);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
