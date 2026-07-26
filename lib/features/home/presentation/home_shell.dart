import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/status_style.dart';
import '../../groups/presentation/groups_screen.dart';
import '../../outcomes/presentation/outcome_screen.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../../scheduling/presentation/planner_activity_screen.dart';

/// The real app home: a bottom-nav shell replacing the dev menu.
///
/// Three role-agnostic tabs — the same person is both a target (My Schedule)
/// and a planner (Activity), so these are tabs, not roles:
///   - Groups       → groups + invites + planner-consent toggles
///   - My Schedule  → the target's approved items (+ pending-approvals inbox)
///   - Activity     → the planner's created items (+ "plan an item" FAB)
///
/// Each tab keeps its own AppBar/title; the shell only owns the NavigationBar.
/// An [IndexedStack] keeps all three mounted so their Firestore listeners stay
/// live and tab state (scroll, selection) survives switching.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const _tabs = [
    GroupsScreen(),
    OutcomeScreen(),
    PlannerActivityScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    // How many items are waiting on this user to decide. Drives the one
    // always-legitimate orange on the shell (UI-RULES.md §2.7) — it renders
    // nothing at zero, so orange never becomes decorative here.
    final pending = ref.watch(myItemsAsTargetProvider).maybeWhen(
          data: (items) => items
              .where((i) => i.status == ScheduleItemStatus.pending)
              .length,
          orElse: () => 0,
        );

    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(AppIcons.navGroups),
            selectedIcon: Icon(AppIcons.navGroupsSelected),
            label: 'Groups',
          ),
          NavigationDestination(
            icon: PendingCountBadge(
                count: pending, child: const Icon(AppIcons.navSchedule)),
            selectedIcon: PendingCountBadge(
                count: pending, child: const Icon(AppIcons.navScheduleSelected)),
            label: 'My Schedule',
          ),
          const NavigationDestination(
            icon: Icon(AppIcons.navActivity),
            selectedIcon: Icon(AppIcons.navActivitySelected),
            label: 'Activity',
          ),
        ],
      ),
    );
  }
}
