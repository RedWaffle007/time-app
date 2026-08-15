import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
///
/// **This is also where hardware Back is handled** — see [_handleBack]. Nothing
/// else in the app intercepts Back; before this, a tab root exited the app
/// silently on the first press (verified on device 2026-08-15, WORK_PLAN.md
/// checklist line A4).
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.navigationShell});

  /// The branch container go_router builds for us; also the tab-state owner
  /// (`currentIndex`) and the only correct way to switch tabs (`goBranch`).
  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// How long the second Back press has to arrive, and how long the prompt is
  /// shown. One value on purpose: a prompt still on screen must mean the window
  /// is still open, or it is telling the user something untrue.
  static const _exitWindow = Duration(seconds: 2);

  /// When the exit prompt was last shown. Null means no window is open.
  DateTime? _exitPromptAt;

  /// Back from a tab root used to finish the activity on the first press.
  ///
  /// Cause was never the shell conversion: `GoRouterDelegate.popRoute()`
  /// (`delegate.dart:57`) asks each current navigator to `maybePop()`, and at a
  /// tab root neither the branch navigator nor the root navigator has anything
  /// to pop, so it returns false and the engine finishes the activity. The app
  /// simply never had back handling — the pre-refactor `IndexedStack` + local
  /// `_index` exited exactly the same way.
  ///
  /// The [PopScope] below therefore sits on the **root** navigator's route (the
  /// shell route is built there), which is what keeps this from swallowing
  /// anything it shouldn't: a pushed detail screen lives in the *branch*
  /// navigator, that navigator is asked first, and it pops normally without this
  /// ever being consulted. Only a genuine "nothing left to pop" reaches here.
  void _handleBack() {
    final shell = widget.navigationShell;
    final messenger = ScaffoldMessenger.of(context);

    // Off the first tab → Back is "go home", not "leave". Plain `goBranch`
    // (no `initialLocation`) restores wherever Groups was left, matching the
    // tab-bar's own switching semantics below.
    if (shell.currentIndex != 0) {
      messenger.hideCurrentSnackBar();
      _exitPromptAt = null;
      shell.goBranch(0);
      return;
    }

    // On Groups, the root of the app: confirm before leaving.
    final now = DateTime.now();
    final promptedAt = _exitPromptAt;
    if (promptedAt != null && now.difference(promptedAt) < _exitWindow) {
      messenger.hideCurrentSnackBar();
      SystemNavigator.pop();
      return;
    }

    _exitPromptAt = now;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        // No action, deliberately: an actioned SnackBar defaults to
        // `persist: true` (snack_bar.dart:303) and would outlive its own
        // window. This one must expire exactly when the window does.
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: _exitWindow,
        ),
      );
  }

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

    final navigationShell = widget.navigationShell;

    return PopScope(
      // Always false: this widget decides what Back means at a tab root, and
      // both outcomes (switch to Groups, prompt-then-exit) are things the
      // framework's default pop cannot express.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          // `initialLocation: true` only when the tab is already selected:
          // tapping the active tab pops that branch back to its root (the
          // standard "tap the tab you're on to go home" gesture), while
          // switching tabs restores wherever that branch was left.
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
                  count: pending,
                  child: const Icon(AppIcons.navScheduleSelected)),
              label: 'My Schedule',
            ),
            const NavigationDestination(
              icon: Icon(AppIcons.navActivity),
              selectedIcon: Icon(AppIcons.navActivitySelected),
              label: 'Activity',
            ),
          ],
        ),
      ),
    );
  }
}
