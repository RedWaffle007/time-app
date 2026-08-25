import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../routing/app_router.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../time_tracking/presentation/log_time_sheet.dart';

/// The app home: the five-PILLAR bottom bar with the docked centre voice FAB
/// (redesign slice S5; UI-RULES.md §6.12).
///
/// `[ Plan · Track · ⊕ voice · Stats · You ]`. The four pillars are branches of
/// the [StatefulNavigationShell]; the ⊕ is NOT a branch but a docked FAB that
/// opens a two-choice sheet (Track time / Plan time), both reachable manually so
/// the FAB is additive. The old three delegation stances (Groups / My Schedule /
/// Activity) are now the keep-alive sub-tabs inside the Plan pillar.
///
/// The bar is a [BottomAppBar] with a circular notch rather than a
/// [NavigationBar] because M3's NavigationBar cannot notch around a docked FAB.
/// Each pillar is a §6.6 filled-selected / outline-unselected icon + label; the
/// Plan pillar carries the §2.7 aggregate attention count.
///
/// **Hardware Back is handled here** — see [_handleBack]. Nothing else in the
/// app intercepts Back.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.navigationShell});

  /// The branch container go_router builds for us; also the tab-state owner
  /// (`currentIndex`) and the only correct way to switch pillars (`goBranch`).
  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  static const _exitWindow = Duration(seconds: 2);

  /// When the exit prompt was last shown. Null means no window is open.
  DateTime? _exitPromptAt;

  /// Back from a pillar root finishes the activity (nothing left to pop); this
  /// intercepts that. Off the first pillar, Back is "go to Plan"; on Plan (the
  /// root of the app), confirm before leaving. See the pre-S5 note history —
  /// the shell was never the cause, the app simply never had Back handling.
  void _handleBack() {
    final shell = widget.navigationShell;
    final messenger = ScaffoldMessenger.of(context);

    // Off the first pillar → Back is "go home" (Plan), not "leave".
    if (shell.currentIndex != 0) {
      messenger.hideCurrentSnackBar();
      _exitPromptAt = null;
      shell.goBranch(0);
      return;
    }

    // On Plan, the root of the app: confirm before leaving.
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
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: _exitWindow,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // The Plan aggregate attention count (redesign S4/S5) — the one always-
    // legitimate orange on the bar (§2.7); renders nothing at zero.
    final planAttention = ref.watch(planAttentionCountProvider);
    final shell = widget.navigationShell;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        body: shell,
        // ONE FAB, always (§6.12): the docked centre voice affordance. Sage,
        // circular, a gentle floating shadow — inviting, not shouting.
        floatingActionButton: FloatingActionButton(
          heroTag: 'voiceFab',
          tooltip: 'Speak to create',
          elevation: Elevations.floating,
          onPressed: _showVoiceSheet,
          child: const Icon(AppIcons.voice),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        bottomNavigationBar: BottomAppBar(
          // Flat scaffold-background chrome with a notch for the FAB (§6.12).
          color: context.colors.surface,
          elevation: Elevations.nav,
          shape: const CircularNotchedRectangle(),
          padding: EdgeInsets.zero,
          child: Row(
            children: [
              _PillarButton(
                index: 0,
                label: 'Plan',
                icon: AppIcons.navPlan,
                selectedIcon: AppIcons.navPlanSelected,
                badgeCount: planAttention,
                shell: shell,
              ),
              _PillarButton(
                index: 1,
                label: 'Track',
                icon: AppIcons.navTrack,
                selectedIcon: AppIcons.navTrackSelected,
                shell: shell,
              ),
              // The gap the notch + FAB occupy.
              const SizedBox(width: Sizes.touchTarget),
              _PillarButton(
                index: 2,
                label: 'Stats',
                icon: AppIcons.navStats,
                selectedIcon: AppIcons.navStatsSelected,
                shell: shell,
              ),
              _PillarButton(
                index: 3,
                label: 'You',
                icon: AppIcons.navYou,
                selectedIcon: AppIcons.navYouSelected,
                shell: shell,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The voice FAB's two-choice sheet (§6.12). No STT yet (S6): each choice opens
  /// the same manual flow it always had, so the FAB is additive from day one.
  ///
  /// Uses the State's own `context` (not a passed one) so the `mounted` guards
  /// below actually cover the context used after the await.
  Future<void> _showVoiceSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(AppIcons.logTime),
              title: const Text('Track time'),
              subtitle: const Text('Log time you spent on something'),
              onTap: () => Navigator.pop(sheetCtx, 'track'),
            ),
            ListTile(
              leading: const Icon(AppIcons.navPlan),
              title: const Text('Plan time'),
              subtitle: const Text('Schedule an item for someone'),
              onTap: () => Navigator.pop(sheetCtx, 'plan'),
            ),
            const SizedBox(height: Space.sm),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'track':
        // The S1 log sheet, empty (STT prefill lands in S6 behind this seam).
        await showLogTimeSheet(context, ref);
      case 'plan':
        // The schedule-builder, whose own first step is picking the target —
        // that IS the person-picker. A Plan sub-route, so Back returns here.
        if (mounted) context.push(Routes.scheduleBuilder);
    }
  }
}

/// One pillar in the bottom bar: a filled-selected / outline-unselected icon +
/// label (§6.6/§6.12), optionally badged (§2.7). Tapping switches pillars;
/// tapping the active pillar pops its branch to root (the standard "tap the tab
/// you're on to go home" gesture).
class _PillarButton extends StatelessWidget {
  const _PillarButton({
    required this.index,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.shell,
    this.badgeCount = 0,
  });

  final int index;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final StatefulNavigationShell shell;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final selected = shell.currentIndex == index;
    final color =
        selected ? context.colors.primary : context.colors.onSurfaceVariant;

    return Expanded(
      child: InkWell(
        // `initialLocation: true` only when already selected: re-tap pops the
        // branch to root; switching restores where that branch was left.
        onTap: () =>
            shell.goBranch(index, initialLocation: index == shell.currentIndex),
        child: SizedBox(
          height: Sizes.touchTarget + Space.lg,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PendingCountBadge(
                count: badgeCount,
                child: Icon(selected ? selectedIcon : icon, color: color),
              ),
              const SizedBox(height: Space.xs),
              Text(label, style: context.text.labelSmall?.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}
