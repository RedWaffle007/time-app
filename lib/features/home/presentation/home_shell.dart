import 'package:flutter/material.dart';

import '../../groups/presentation/groups_screen.dart';
import '../../outcomes/presentation/outcome_screen.dart';
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
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _tabs = [
    GroupsScreen(),
    OutcomeScreen(),
    PlannerActivityScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.group_outlined),
            selectedIcon: Icon(Icons.group),
            label: 'Groups',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_outlined),
            selectedIcon: Icon(Icons.event),
            label: 'My Schedule',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'Activity',
          ),
        ],
      ),
    );
  }
}
