import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/groups/application/group_board.dart';
import 'package:time_app/features/groups/application/group_providers.dart';
import 'package:time_app/features/groups/application/group_stats_providers.dart';
import 'package:time_app/features/groups/domain/group.dart';
import 'package:time_app/features/groups/domain/group_member_stat.dart';
import 'package:time_app/features/groups/presentation/group_progress_screen.dart';
import 'package:time_app/features/social/domain/profile_stat.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// Group progress (item 24d): group-scoped numbers, current members only,
/// minimum sample before ranking, and "N of M kept it going".
void main() {
  setUpAll(tzdata.initializeTimeZones);

  const zone = 'Asia/Karachi'; // UTC+5, no DST.
  const groupId = 'group_1';

  StatItem item({
    required int day,
    String group = groupId,
    bool done = false,
    bool skipped = false,
    bool missed = false,
    bool cancelled = false,
  }) => StatItem(
    instantUtc: DateTime.utc(2026, 9, day, 7),
    isDone: done,
    isSkipped: skipped || missed,
    isMissed: missed,
    isCancelled: cancelled,
    groupId: group,
  );

  GroupMemberStat row(
    String uid, {
    int done = 0,
    int answered = 0,
    int streak = 0,
    String? name,
  }) => GroupMemberStat(
    uid: uid,
    name: name ?? uid,
    tasksCompleted: done,
    answered: answered,
    currentStreak: streak,
    bestStreak: streak,
  );

  group('groupScopedStat', () {
    test('counts only this group\'s plans, cancelled excluded', () {
      final stat = groupScopedStat(
        uid: 'me',
        name: 'Test Member',
        groupId: groupId,
        timezone: zone,
        itemsAsTarget: [
          item(day: 20, done: true),
          item(day: 21, done: true),
          item(day: 22, skipped: true),
          item(day: 23, missed: true),
          item(day: 24, done: true, cancelled: true),
          item(day: 25, done: true, group: 'other_group'),
          item(day: 26, done: true, group: ''), // friend plan
        ],
      );
      expect(stat.tasksCompleted, 2);
      expect(stat.answered, 4);
    });

    test('streaks use the humane rule over group plans only', () {
      final stat = groupScopedStat(
        uid: 'me',
        name: 'Test Member',
        groupId: groupId,
        timezone: zone,
        itemsAsTarget: [
          item(day: 20, done: true),
          item(day: 21, missed: true),
          item(day: 22, done: true),
          item(day: 24, done: true), // 23 neutral
          item(day: 23, missed: true, group: ''), // not this group's
        ],
      );
      expect(stat.currentStreak, 2);
      expect(stat.bestStreak, 2);
    });
  });

  group('GroupMemberStat.followThrough', () {
    test('null below the sample, a percent at or above it', () {
      expect(row('a', done: 1, answered: 1).followThrough, isNull);
      expect(row('a', done: 4, answered: 5).followThrough, 80);
    });
  });

  group('buildGroupBoard', () {
    test('only current members appear — a leaver\'s row is dropped', () {
      final board = buildGroupBoard(
        [row('a', done: 5, answered: 5), row('gone', done: 9, answered: 9)],
        ['a', 'b'],
      );
      expect([...board.ranked, ...board.unranked].map((r) => r.uid), ['a']);
      expect(board.memberCount, 1);
    });

    test('1 of 1 never outranks 49 of 50', () {
      final board = buildGroupBoard(
        [row('tiny', done: 1, answered: 1), row('big', done: 49, answered: 50)],
        ['tiny', 'big'],
      );
      expect(board.ranked.map((r) => r.uid), ['big']);
      expect(board.unranked.map((r) => r.uid), ['tiny']);
    });

    test('ranked by follow-through, then done, then name', () {
      final board = buildGroupBoard(
        [
          row('c', done: 8, answered: 10, name: 'Cee'),
          row('a', done: 4, answered: 5, name: 'Bee'),
          row('b', done: 4, answered: 5, name: 'Aye'),
          row('d', done: 10, answered: 10, name: 'Dee'),
        ],
        ['a', 'b', 'c', 'd'],
      );
      expect(board.ranked.map((r) => r.uid), ['d', 'c', 'b', 'a']);
    });

    test('unranked members are listed by name, never as 0%', () {
      final board = buildGroupBoard(
        [row('z', name: 'Zed'), row('y', done: 1, answered: 2, name: 'Amy')],
        ['z', 'y'],
      );
      expect(board.ranked, isEmpty);
      expect(board.unranked.map((r) => r.name), ['Amy', 'Zed']);
    });

    test('kept streak counts members with a run going', () {
      final board = buildGroupBoard(
        [row('a', streak: 3), row('b'), row('c', streak: 1), row('d')],
        ['a', 'b', 'c', 'd'],
      );
      expect(board.keptStreak, 2);
      expect(board.memberCount, 4);
    });

    test('group follow-through is pooled, and sampled', () {
      final pooled = buildGroupBoard(
        [row('a', done: 1, answered: 1), row('b', done: 2, answered: 4)],
        ['a', 'b'],
      );
      expect(pooled.followThrough, 60); // 3 of 5, not the mean of 100 and 50
      final small = buildGroupBoard(
        [row('a', done: 1, answered: 1), row('b', done: 2, answered: 3)],
        ['a', 'b'],
      );
      expect(small.followThrough, isNull);
    });

    test('a pre-24d row (no answered) is unranked, not an error', () {
      final board = buildGroupBoard([row('old', done: 7)], ['old']);
      expect(board.unranked.single.uid, 'old');
      expect(board.hasNoAnswers, isTrue);
    });
  });

  group('GroupProgressScreen', () {
    const team = Group(
      id: groupId,
      name: 'Test Group',
      ownerUid: 'a',
      joinCode: 'ABC234',
      memberUids: ['a', 'b', 'c'],
    );

    Widget harness(List<GroupMemberStat> rows, {ThemeData? theme}) =>
        ProviderScope(
          overrides: [
            myGroupsProvider.overrideWithValue(const AsyncData([team])),
            groupMemberStatsProvider(
              groupId,
            ).overrideWithValue(AsyncData(rows)),
          ],
          child: MaterialApp(
            theme: theme ?? AppTheme.light,
            home: const GroupProgressScreen(groupId: groupId),
          ),
        );

    testWidgets('empty until someone answers a group plan', (tester) async {
      await tester.pumpWidget(harness([row('a'), row('b')]));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('No group plans answered yet'),
        findsOneWidget,
      );
    });

    testWidgets('renders ranked and getting-started members', (tester) async {
      await tester.pumpWidget(
        harness([
          row('a', done: 8, answered: 10, streak: 2, name: 'Planner One'),
          row('b', done: 1, answered: 1, name: 'Planner Two'),
          row('gone', done: 9, answered: 9, name: 'Left The Group'),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Test Group'), findsOneWidget);
      expect(find.text('1 of 2 kept their streak going.'), findsOneWidget);
      expect(
        find.text('Group follow-through: 82% on plans made in this group.'),
        findsOneWidget,
      );
      expect(find.text('Leaderboard'), findsOneWidget);
      expect(find.text('80%'), findsOneWidget);
      expect(find.text('Getting started'), findsOneWidget);
      expect(find.text('Needs 5 answered'), findsOneWidget);
      expect(find.text('Left The Group'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dark theme renders without exceptions', (tester) async {
      await tester.pumpWidget(
        harness([row('a', done: 5, answered: 5)], theme: AppTheme.dark),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
