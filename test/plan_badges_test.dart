import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/plan_badge_style.dart';
import 'package:time_app/core/theme/status_style.dart';
import 'package:time_app/features/archive/application/archive_providers.dart';
import 'package:time_app/features/archive/data/archive_repository.dart';
import 'package:time_app/features/archive/presentation/archive_menu_button.dart';
import 'package:time_app/features/archive/presentation/archived_screen.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/data/auth_repository.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/planner_activity_screen.dart';
import 'package:timezone/data/latest.dart' as tz_data;

/// Plan badges (2026-09-28, DECISIONS.md "Plan badges"): Sent / Self /
/// Received + Group top-right; status and the card's one action (Archive,
/// Unarchive, Cancel alarm) on the bottom row — never colliding.

class _Auth implements AuthRepository {
  @override
  User? get currentUser => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Archive implements ArchiveRepository {
  final archived = <String>[];

  @override
  Future<void> archive(String uid, String itemId) async =>
      archived.add('$uid/$itemId');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ScheduleItem _plan(
  String id, {
  String target = 'me',
  String creator = 'friend',
  String group = '',
  ScheduleOutcome? outcome,
  ScheduleItemStatus status = ScheduleItemStatus.approved,
  Duration fromNow = const Duration(hours: 3),
}) => ScheduleItem(
  id: id,
  targetUid: target,
  createdByUid: creator,
  groupId: group,
  title: 'Title $id',
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: DateTime.now().toUtc().add(fromNow),
  status: status,
  outcome: outcome,
);

const _done = ScheduleOutcome(result: OutcomeResult.done);

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  setUpAll(tz_data.initializeTimeZones);

  group('ownership', () {
    test('self / received / sent', () {
      expect(
        planOwnership(_plan('a', creator: 'me'), iAmTarget: true),
        PlanOwnership.self,
      );
      expect(
        planOwnership(_plan('b', target: 'x', creator: 'x'), iAmTarget: false),
        PlanOwnership.self,
      );
      expect(
        planOwnership(_plan('c'), iAmTarget: true),
        PlanOwnership.received,
      );
      expect(
        planOwnership(
          _plan('d', target: 'friend', creator: 'me'),
          iAmTarget: false,
        ),
        PlanOwnership.sent,
      );
    });

    test('one word each', () {
      expect(PlanOwnership.values.map(planOwnershipLabel), [
        'Sent',
        'Self',
        'Received',
      ]);
      expect(kGroupPlanBadgeLabel, 'Group');
    });
  });

  for (final theme in [AppTheme.light, AppTheme.dark]) {
    testWidgets('four distinct accents, none a system hue, AA on cards '
        '(${theme.brightness})', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final colors = [
        for (final o in PlanOwnership.values) planOwnershipColor(ctx, o),
        groupPlanBadgeColor(ctx),
      ];
      expect(colors.toSet(), hasLength(4));
      final scheme = Theme.of(ctx).colorScheme;
      for (final c in colors) {
        expect(c, isNot(scheme.primary));
        expect(c, isNot(ctx.attention));
        expect(c, isNot(scheme.error));
        expect(_contrast(c, scheme.surface), greaterThanOrEqualTo(4.5));
      }
    });
  }

  Future<_Archive> pump(
    WidgetTester tester,
    Widget child, {
    ThemeData? theme,
    bool reduceMotion = false,
    List<ScheduleItem> archived = const [],
  }) async {
    final archive = _Archive();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          profileByUidProvider.overrideWith(
            (ref, uid) => Stream.value(
              UserProfile(uid: uid, name: 'Name $uid', homeTimezone: 'Etc/UTC'),
            ),
          ),
          archiveRepositoryProvider.overrideWithValue(archive),
          authRepositoryProvider.overrideWithValue(_Auth()),
          archivedItemsProvider.overrideWithValue(AsyncData(archived)),
        ],
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: MaterialApp(
            theme: theme ?? AppTheme.light,
            home: Scaffold(body: ListView(children: [child])),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return archive;
  }

  testWidgets('a plan someone set for me reads Received, no Group', (
    tester,
  ) async {
    await pump(tester, OutcomeCard(item: _plan('r')));
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Group'), findsNothing);
    expect(find.text('Sent'), findsNothing);
  });

  testWidgets('my own plan reads Self', (tester) async {
    await pump(tester, OutcomeCard(item: _plan('s', creator: 'me')));
    expect(find.text('Self'), findsOneWidget);
  });

  testWidgets('a group plan for me reads Received AND Group', (tester) async {
    await pump(tester, OutcomeCard(item: _plan('g', group: 'grp')));
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Group'), findsOneWidget);
  });

  testWidgets(
    'layout A: badges top-right, status + Archive on the bottom row',
    (tester) async {
      final archive = await pump(
        tester,
        OutcomeCard(
          item: _plan(
            'done',
            group: 'grp',
            outcome: _done,
            fromNow: const Duration(hours: -2),
          ),
        ),
      );
      final title = tester.getRect(find.text('Title done'));
      final received = tester.getRect(find.text('Received'));
      final status = tester.getRect(find.byType(StatusBadge));
      final archiveButton = find.byKey(const ValueKey('archive-done'));
      expect(archiveButton, findsOneWidget);
      // Badge on the title's row, to its right.
      expect(received.center.dy, closeTo(title.center.dy, 12));
      expect(received.left, greaterThan(title.right - 1));
      // Status below, never beside the ownership badge.
      expect(status.top, greaterThan(received.bottom));
      expect(tester.getRect(archiveButton).left, greaterThan(status.right));
      // No ⋮ menu any more.
      expect(find.byTooltip('More'), findsNothing);

      await tester.tap(archiveButton);
      await tester.pumpAndSettle();
      expect(archive.archived, ['me/done']);
      expect(find.text('Archived. Hidden from your views only.'), findsOne);
    },
  );

  testWidgets('an open plan offers no Archive', (tester) async {
    await pump(tester, OutcomeCard(item: _plan('open')));
    expect(find.byType(ArchiveButton), findsNothing);
  });

  testWidgets('a plan I set for a friend reads Sent, Cancel alarm below', (
    tester,
  ) async {
    await pump(
      tester,
      PlannerItemCard(
        item: _plan('p', target: 'friend', creator: 'me'),
      ),
    );
    expect(find.text('Sent'), findsOneWidget);
    final sent = tester.getRect(find.text('Sent'));
    final cancel = tester.getRect(
      find.byKey(const ValueKey('planner-cancel-alarm')),
    );
    expect(cancel.top, greaterThan(sent.bottom));
    expect(find.byType(ArchiveButton), findsNothing);
  });

  testWidgets('an answered group plan I set: Sent + Group, status, Archive', (
    tester,
  ) async {
    await pump(
      tester,
      PlannerItemCard(
        item: _plan(
          'pg',
          target: 'friend',
          creator: 'me',
          group: 'grp',
          outcome: _done,
          fromNow: const Duration(hours: -1),
        ),
      ),
    );
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Group'), findsOneWidget);
    expect(find.byType(StatusBadge), findsOneWidget);
    expect(find.byKey(const ValueKey('archive-pg')), findsOneWidget);
    expect(
      tester.getRect(find.byType(StatusBadge)).top,
      greaterThan(tester.getRect(find.text('Sent')).bottom),
    );
  });

  testWidgets('the Archived screen carries the same badges', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final archived = [
      _plan('a1', outcome: _done, fromNow: const Duration(hours: -1)),
      _plan(
        'a2',
        target: 'friend',
        creator: 'me',
        group: 'grp',
        outcome: _done,
        fromNow: const Duration(hours: -2),
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          profileByUidProvider.overrideWith((ref, uid) => Stream.value(null)),
          archivedItemsProvider.overrideWithValue(AsyncData(archived)),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const ArchivedScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Group'), findsOneWidget);
    expect(find.text('Unarchive'), findsNWidgets(2));
  });

  testWidgets('reduced motion: no sheen animation runs', (tester) async {
    await pump(tester, OutcomeCard(item: _plan('m')), reduceMotion: true);
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('Received'), findsOneWidget);
  });

  testWidgets('the sheen sweeps again every few seconds, and settles between', (
    tester,
  ) async {
    await pump(tester, OutcomeCard(item: _plan('m2')));
    // pumpAndSettle returned: nothing animates between sweeps.
    expect(tester.hasRunningAnimations, isFalse);
    // Device report 2026-09-28: one sweep was easy to miss. It repeats.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    // Leaving the screen cancels the next sweep (no timer left behind).
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('every badge shines: Sent and Group too', (tester) async {
    await pump(
      tester,
      PlannerItemCard(
        item: _plan('sg', target: 'friend', creator: 'me', group: 'grp'),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 100));
    for (final key in ['plan-badge-sent', 'plan-badge-group']) {
      final painter = find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(CustomPaint),
      );
      expect(painter, findsWidgets, reason: key);
    }
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dark mode and a 320 px phone: no overflow', (tester) async {
    tester.view.physicalSize = const Size(960, 1600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      PlannerItemCard(
        item: _plan(
          'long',
          target: 'friend',
          creator: 'me',
          group: 'grp',
          outcome: _done,
          fromNow: const Duration(hours: -1),
        ),
      ),
      theme: AppTheme.dark,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late Done with a long reason fits a 320 px phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 1600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      OutcomeCard(
        item: _plan(
          'narrow',
          group: 'grp',
          outcome: const ScheduleOutcome(
            result: OutcomeResult.skipped,
            skipReason: 'A long reason that needs to wrap onto another line',
          ),
          fromNow: const Duration(hours: -1),
        ),
      ),
      theme: AppTheme.dark,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('archive-narrow')), findsOneWidget);
  });
}
