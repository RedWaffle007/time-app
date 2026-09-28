import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/groups/application/group_providers.dart';
import 'package:time_app/features/outcomes/application/schedule_partition.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest.dart' as tz_data;

/// Home's three headings (2026-09-28): Upcoming Plans = not rung yet (mine,
/// self or from others, and plans I set for others); once a plan rings it
/// waits under Waiting on You (mine) or Waiting on Them (theirs).
void main() {
  setUpAll(tz_data.initializeTimeZones);

  ScheduleItem plan(
    String id, {
    required DateTime at,
    String target = 'me',
    String creator = 'friend',
  }) => ScheduleItem(
    id: id,
    targetUid: target,
    createdByUid: creator,
    groupId: '',
    title: id,
    localWallTime: '',
    timezone: 'Etc/UTC',
    scheduledInstantUtc: at,
    status: ScheduleItemStatus.approved,
  );

  group('homeSectionFor', () {
    final now = DateTime.utc(2030, 1, 1, 12);
    HomeSection section(ScheduleItem item) =>
        homeSectionFor(item, now, isMine: item.targetUid == 'me');
    test('not rung yet is Upcoming, whoever it is for', () {
      final later = now.add(const Duration(minutes: 1));
      expect(section(plan('a', at: later)), HomeSection.upcoming);
      expect(
        section(plan('b', at: later, target: 'me', creator: 'me')),
        HomeSection.upcoming,
      );
      expect(
        section(plan('c', at: later, target: 'friend', creator: 'me')),
        HomeSection.upcoming,
      );
    });

    test('rung: mine (self or from others) waits on me', () {
      expect(section(plan('a', at: now)), HomeSection.waitingOnYou);
      expect(
        section(
          plan('b', at: now.subtract(const Duration(hours: 1)), creator: 'me'),
        ),
        HomeSection.waitingOnYou,
      );
    });

    test('rung: a plan I set for someone else waits on them', () {
      expect(
        section(plan('a', at: now, target: 'friend', creator: 'me')),
        HomeSection.waitingOnThem,
      );
    });
  });

  Widget host({
    List<ScheduleItem> mine = const [],
    List<ScheduleItem> planned = const [],
    String? highlight,
    int token = 0,
  }) => ProviderScope(
    overrides: [
      currentUidProvider.overrideWithValue('me'),
      myItemsAsTargetProvider.overrideWithValue(AsyncData(mine)),
      myItemsAsPlannerProvider.overrideWithValue(AsyncData(planned)),
      myGroupsProvider.overrideWithValue(const AsyncData([])),
      profileByUidProvider.overrideWith(
        (ref, uid) => Stream.value(
          UserProfile(uid: uid, name: 'Name $uid', homeTimezone: 'Etc/UTC'),
        ),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: OutcomeScreen(highlightItemId: highlight, highlightToken: token),
    ),
  );

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  double top(WidgetTester tester, Finder f) => tester.getTopLeft(f.first).dy;

  testWidgets('each plan sits under its heading, waiting ones first', (
    tester,
  ) async {
    tall(tester);
    final now = DateTime.now().toUtc();
    final past = now.subtract(const Duration(hours: 1));
    final future = now.add(const Duration(hours: 3));
    await tester.pumpWidget(
      host(
        mine: [
          plan('Rang for me', at: past),
          plan('Rang self', at: past, creator: 'me'),
          plan('Later for me', at: future),
        ],
        planned: [
          plan('Rang for them', at: past, target: 'friend', creator: 'me'),
          plan('Later for them', at: future, target: 'friend', creator: 'me'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final you = find.byKey(const ValueKey('home-waiting-on-you'));
    final them = find.byKey(const ValueKey('home-waiting-on-them'));
    final upcoming = find.text('Upcoming Plans');
    expect(you, findsOneWidget);
    expect(them, findsOneWidget);
    expect(find.text('Waiting on You'), findsOneWidget);
    expect(find.text('Waiting on Them'), findsOneWidget);

    expect(top(tester, you), lessThan(top(tester, them)));
    expect(top(tester, them), lessThan(top(tester, upcoming)));
    for (final title in ['Rang for me', 'Rang self']) {
      final y = top(tester, find.text(title));
      expect(y, greaterThan(top(tester, you)), reason: title);
      expect(y, lessThan(top(tester, them)), reason: title);
    }
    final rangForThem = top(tester, find.text('Rang for them'));
    expect(rangForThem, greaterThan(top(tester, them)));
    expect(rangForThem, lessThan(top(tester, upcoming)));
    for (final title in ['Later for me', 'Later for them']) {
      // `.last`: the hero band at the top also names MY next plan.
      expect(
        tester.getTopLeft(find.text(title).last).dy,
        greaterThan(top(tester, upcoming)),
        reason: title,
      );
    }
  });

  testWidgets('my rung plan waits on me even before my uid resolves', (
    tester,
  ) async {
    // Classified by which stream it came from, not by comparing uids.
    tall(tester);
    final past = DateTime.now().toUtc().subtract(const Duration(minutes: 3));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myItemsAsTargetProvider.overrideWithValue(
            AsyncData([plan('Rang', at: past)]),
          ),
          profileByUidProvider.overrideWith((ref, uid) => Stream.value(null)),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const OutcomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Waiting on You'), findsOneWidget);
    expect(find.text('Waiting on Them'), findsNothing);
  });

  testWidgets('empty headings are hidden', (tester) async {
    tall(tester);
    final future = DateTime.now().toUtc().add(const Duration(hours: 3));
    await tester.pumpWidget(host(mine: [plan('Later', at: future)]));
    await tester.pumpAndSettle();
    expect(find.text('Waiting on You'), findsNothing);
    expect(find.text('Waiting on Them'), findsNothing);
    expect(find.text('Upcoming Plans'), findsOneWidget);
  });

  testWidgets('a plan moves to Waiting the moment it rings', (tester) async {
    tall(tester);
    final soon = DateTime.now().toUtc().add(const Duration(seconds: 1));
    await tester.pumpWidget(
      host(
        mine: [plan('Mine soon', at: soon)],
        planned: [
          plan('Theirs soon', at: soon, target: 'friend', creator: 'me'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Waiting on You'), findsNothing);
    expect(find.text('Waiting on Them'), findsNothing);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1200)),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Waiting on You'), findsOneWidget);
    expect(find.text('Waiting on Them'), findsOneWidget);
  });

  testWidgets('a link to a far Waiting plan scrolls to it (calendar)', (
    tester,
  ) async {
    // Regression (device report 2026-09-28): from the Calendar, a plan that
    // had already rung opened Home but not the plan itself.
    final now = DateTime.now().toUtc();
    final mine = [
      for (var i = 0; i < 40; i++)
        plan('Rang $i', at: now.subtract(Duration(minutes: i + 1))),
    ];
    // Newest first: 'Rang 39' is the last card, far below the fold.
    await tester.pumpWidget(host(mine: mine));
    await tester.pumpAndSettle();
    final screen = tester.getRect(find.byType(Scaffold).first);
    bool onScreen() {
      final hits = find.text('Rang 39');
      if (hits.evaluate().isEmpty) return false;
      final r = tester.getRect(hits.first);
      return r.bottom > screen.top && r.top < screen.bottom;
    }

    expect(onScreen(), isFalse);
    await tester.pumpWidget(host(mine: mine, highlight: 'Rang 39', token: 1));
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(onScreen(), isTrue);
  });
}
