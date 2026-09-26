import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/status_style.dart';
import 'package:time_app/features/groups/application/group_providers.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/plan/presentation/plan_shell.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:timezone/data/latest.dart' as tz_data;

/// Regression pins for the 2026-09-26 device report: the pending count sat on
/// the "My Schedule" tab label instead of the Pending approvals icon, and the
/// icon was hard to find (UI-RULES §6.2a).
class _Items extends Notifier<List<ScheduleItem>> {
  @override
  List<ScheduleItem> build() => const [];

  void set(List<ScheduleItem> items) => state = items;
}

final _itemsProvider = NotifierProvider<_Items, List<ScheduleItem>>(_Items.new);

Future<ProviderContainer> _pumpShell(
  WidgetTester tester,
  List<ScheduleItem> items, {
  ThemeData? theme,
  Widget home = const PlanShell(),
}) async {
  final container = ProviderContainer(
    overrides: [
      myItemsAsTargetProvider.overrideWith(
        (ref) => AsyncData(ref.watch(_itemsProvider)),
      ),
      myItemsAsPlannerProvider.overrideWithValue(const AsyncData([])),
      myGroupsProvider.overrideWithValue(const AsyncData([])),
      profileByUidProvider.overrideWith((ref, uid) => Stream.value(null)),
    ],
  );
  addTearDown(container.dispose);
  container.read(_itemsProvider.notifier).set(items);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: theme ?? AppTheme.light, home: home),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder get _approvalsButton => find.byWidgetPredicate(
  (w) => w is IconButton && (w.tooltip ?? '').startsWith('Pending approvals'),
);

Finder get _glow => find.byKey(PendingAttentionGlow.glowKey);

Finder _badgeText(String n) =>
    find.descendant(of: _approvalsButton, matching: find.text(n));

void main() {
  setUpAll(tz_data.initializeTimeZones);

  final future = DateTime.now().toUtc().add(const Duration(days: 1));

  testWidgets('no pending plans: no badge, no glow, plain tooltip', (
    tester,
  ) async {
    await _pumpShell(tester, [_item('a', future, ScheduleItemStatus.approved)]);

    expect(_approvalsButton, findsOneWidget);
    expect(find.byTooltip('Pending approvals'), findsOneWidget);
    expect(find.byType(Badge), findsNothing);
    expect(_glow, findsNothing);
  });

  testWidgets('the real count sits on the approvals icon, not the tab', (
    tester,
  ) async {
    await _pumpShell(tester, [
      _item('a', future, ScheduleItemStatus.pending),
      _item('b', future, ScheduleItemStatus.pending),
      _item('c', future, ScheduleItemStatus.approved),
    ]);

    expect(_badgeText('2'), findsOneWidget);
    expect(find.byTooltip('Pending approvals, 2 waiting'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('My Schedule'), matching: find.byType(Badge)),
      findsNothing,
      reason: 'the tab label must never carry the pending count again',
    );
    expect(
      find.ancestor(of: find.text('2'), matching: find.byType(Tab)),
      findsNothing,
    );
    expect(_glow, findsOneWidget);
    expect(
      find.descendant(of: _approvalsButton, matching: _glow),
      findsOneWidget,
    );
  });

  testWidgets(
    'deciding plans drops the count, and the last one ends the glow',
    (tester) async {
      final container = await _pumpShell(tester, [
        _item('a', future, ScheduleItemStatus.pending),
        _item('b', future, ScheduleItemStatus.pending),
      ]);
      expect(_badgeText('2'), findsOneWidget);

      container.read(_itemsProvider.notifier).set([
        _item('a', future, ScheduleItemStatus.approved),
        _item('b', future, ScheduleItemStatus.pending),
      ]);
      await tester.pumpAndSettle();
      expect(_badgeText('1'), findsOneWidget);
      expect(_glow, findsOneWidget, reason: 'still one waiting');

      container.read(_itemsProvider.notifier).set([
        _item('a', future, ScheduleItemStatus.approved),
        _item('b', future, ScheduleItemStatus.rejected),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(Badge), findsNothing);
      expect(_glow, findsNothing);
    },
  );

  testWidgets('icon badge always equals the Plan pillar provider', (
    tester,
  ) async {
    final container = await _pumpShell(tester, [
      for (var i = 0; i < 3; i++)
        _item('p$i', future, ScheduleItemStatus.pending),
      _item('x', future, ScheduleItemStatus.withdrawn),
    ]);
    final count = container.read(planAttentionCountProvider);
    expect(count, 3);
    expect(_badgeText('$count'), findsOneWidget);
  });

  for (final (name, theme, alpha) in [
    ('light', AppTheme.light, 0.45),
    ('dark', AppTheme.dark, 0.6),
  ]) {
    testWidgets('the glow uses the attention role in $name mode', (
      tester,
    ) async {
      await _pumpShell(tester, [
        _item('a', future, ScheduleItemStatus.pending),
      ], theme: theme);

      final box = tester.widget<DecoratedBox>(_glow);
      final shadow = (box.decoration as BoxDecoration).boxShadow!.single;
      final attention = tester.element(_glow).attention;
      expect(shadow.color, attention.withValues(alpha: alpha));
      expect(shadow.blurRadius, greaterThan(0));
    });
  }

  testWidgets('the glow is static: nothing keeps animating', (tester) async {
    await _pumpShell(tester, [_item('a', future, ScheduleItemStatus.pending)]);
    // pumpAndSettle in _pumpShell would time out on a repeating animation;
    // assert again explicitly so a future "pulse" cannot slip in unnoticed.
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('the standalone My Schedule app bar uses the same action', (
    tester,
  ) async {
    await _pumpShell(tester, [
      _item('a', future, ScheduleItemStatus.pending),
    ], home: const OutcomeScreen());

    expect(find.byType(PendingApprovalsAction), findsOneWidget);
    expect(_badgeText('1'), findsOneWidget);
    expect(_glow, findsOneWidget);
  });

  test('tooltip copy', () {
    expect(PendingApprovalsAction.tooltipFor(0), 'Pending approvals');
    expect(
      PendingApprovalsAction.tooltipFor(3),
      'Pending approvals, 3 waiting',
    );
  });
}

ScheduleItem _item(String id, DateTime instant, ScheduleItemStatus status) =>
    ScheduleItem(
      id: id,
      targetUid: 'TARGET',
      createdByUid: 'PLANNER',
      groupId: '',
      title: 'Task $id',
      localWallTime: '',
      timezone: 'Etc/UTC',
      scheduledInstantUtc: instant,
      status: status,
    );
