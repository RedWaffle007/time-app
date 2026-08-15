import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/status_style.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';

/// The real app home: a bottom-nav shell replacing the dev menu.
///
/// Three role-agnostic tabs — the same person is both a target (My Schedule)
/// and a planner (Activity), so these are tabs, not roles:
///   - Groups       → groups + invites + planner-consent toggles
///   - My Schedule  → the target's approved items (+ pending-approvals inbox)
///   - Activity     → the planner's created items (+ "plan an item" FAB)
///
/// Each tab keeps its own AppBar/title; the shell only owns the NavigationBar.
///
/// The tabs are **routes**, not a local `_index` over an [IndexedStack]. That
/// was D2: the same three screens were registered both here as tabs and in the
/// router as flat top-level paths, so a notification `go('/approvals')` replaced
/// the whole stack and landed the user on a bare screen with no nav bar and no
/// back — `PendingApprovalsScreen` had no exit at all. A
/// [StatefulShellRoute.indexedStack] makes each tab a branch with its own
/// navigator, so there is exactly one registration per screen, deep pushes keep
/// the bar beneath them, and every tab keeps its own back stack. The indexed
/// stack still holds all three mounted, so Firestore listeners stay live and
/// scroll/selection survives switching, exactly as before.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});

  /// The branch container go_router builds for us; also the tab-state owner
  /// (`currentIndex`) and the only correct way to switch tabs (`goBranch`).
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        // `initialLocation: true` only when the tab is already selected: tapping
        // the active tab pops that branch back to its root (the standard "tap
        // the tab you're on to go home" gesture), while switching tabs restores
        // wherever that branch was left.
        onDestinationSelected: (i) => navigationShell.goBranch(
          i,
          initialLocation: i == navigationShell.currentIndex,
        ),
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
