import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../auth/application/auth_providers.dart';
import '../../plan_requests/application/plan_request_providers.dart';
import '../../walkthrough/application/walkthrough_providers.dart';
import '../../walkthrough/presentation/walkthrough_overlay.dart';
import '../../invites/presentation/pending_invite_listener.dart';

/// The app home: the four-PILLAR bottom bar (redesign slice S5; UI-RULES.md
/// §6.12).
///
/// `[ Plan · Request · Stats · You ]`, each a branch of the
/// [StatefulNavigationShell]. The centre ⊕ voice button and its spoken-plan
/// flow were removed 2026-09-27 (user-directed); Track Time went earlier
/// (Batch G item 8; Request took its slot). The old three delegation stances
/// (Groups / My Schedule / Activity) are now the keep-alive sub-tabs inside
/// the Plan pillar.
///
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

  // --- first-run orientation tour (S-walkthrough) -------------------------
  //
  // The coach-mark targets: the four pillars. Keys are
  // owned here (not by the buttons) so the overlay can spotlight each. The bar
  // is persistent, so these are always laid out — the tour reads their rects
  // directly.
  final _planKey = GlobalKey();
  final _requestKey = GlobalKey();
  final _statsKey = GlobalKey();
  final _youKey = GlobalKey();

  bool _walkthroughVisible = false;

  /// The avatar URL already warmed into the image cache (see build).
  String? _warmedAvatarUrl;

  /// The first-run auto-show fires at most once per shell lifetime; replay comes
  /// through [walkthroughTriggerProvider], not this latch.
  bool _autoShowChecked = false;

  List<WalkthroughStep> _walkthroughSteps() => [
        WalkthroughStep(
          copy: kWalkthroughStepCopy[0],
          targetKey: _planKey,
          spotlightRadius: Radii.md,
        ),
        WalkthroughStep(
          copy: kWalkthroughStepCopy[1],
          targetKey: _requestKey,
          spotlightRadius: Radii.md,
        ),
        WalkthroughStep(
          copy: kWalkthroughStepCopy[2],
          targetKey: _statsKey,
          spotlightRadius: Radii.md,
        ),
        WalkthroughStep(
          copy: kWalkthroughStepCopy[3],
          targetKey: _youKey,
          spotlightRadius: Radii.md,
        ),
      ];

  /// Land on Plan (so the page behind the tour matches the first spotlight) and
  /// raise the overlay. Used by both first-run and replay.
  void _startWalkthrough() {
    if (!mounted) return;
    widget.navigationShell.goBranch(0);
    setState(() => _walkthroughVisible = true);
  }

  /// Skip or Done — hide the overlay and record completion so it never auto-shows
  /// again. Safe to call after a replay (writes `true` over `true`).
  void _finishWalkthrough() {
    if (mounted) setState(() => _walkthroughVisible = false);
    markWalkthroughCompleted(ref);
  }

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
    final shell = widget.navigationShell;

    // First run on this device: auto-show the orientation tour once, after the
    // permissions gate (this shell is only reached past it). Watching the flag
    // is cheap and only ever flips this latch true.
    final walkthroughDone = ref.watch(walkthroughCompletedProvider);
    if (!_autoShowChecked && walkthroughDone.value == false) {
      _autoShowChecked = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _startWalkthrough());
    }
    // Warm my own picture as soon as the app is up (2026-09-27): the You tab
    // is built on first visit, so its `Image.network` only started the
    // download then and the initial showed for a few seconds. Fetched once
    // per URL into the image cache the avatar then reads from.
    final myAvatarUrl = ref.watch(
      profileProvider.select((p) => p.value?.displayAvatarUrl),
    );
    if (myAvatarUrl != null && myAvatarUrl != _warmedAvatarUrl) {
      _warmedAvatarUrl = myAvatarUrl;
      precacheImage(
        NetworkImage(myAvatarUrl),
        context,
        onError: (_, _) {}, // The avatar falls back to the initial itself.
      );
    }
    // Replay from the You hub — a nonce bump, orthogonal to the flag above.
    ref.listen<int>(walkthroughTriggerProvider, (prev, next) {
      if (prev != next) _startWalkthrough();
    });

    // Invite links act here, past every gate (item 17).
    return PendingInviteListener(
      child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Stack(
        children: [
          Scaffold(
        body: shell,
        bottomNavigationBar: BottomAppBar(
          // Flat scaffold-background chrome (§6.12).
          color: context.colors.surface,
          elevation: Elevations.nav,
          padding: EdgeInsets.zero,
          child: Row(
            children: [
              _PillarButton(
                index: 0,
                label: 'Plan',
                icon: AppIcons.navPlan,
                selectedIcon: AppIcons.navPlanSelected,
                // No approval queue any more (F2), so nothing waits on Plan.
                badgeCount: 0,
                shell: shell,
                spotlightKey: _planKey,
              ),
              _PillarButton(
                index: 1,
                label: 'Request',
                icon: AppIcons.navRequest,
                selectedIcon: AppIcons.navRequestSelected,
                // Plan requests waiting on me (§2.7 attention count).
                badgeCount: ref.watch(incomingPlanRequestCountProvider),
                shell: shell,
                spotlightKey: _requestKey,
              ),
              _PillarButton(
                index: 2,
                label: 'Stats',
                icon: AppIcons.navStats,
                selectedIcon: AppIcons.navStatsSelected,
                shell: shell,
                spotlightKey: _statsKey,
              ),
              _PillarButton(
                index: 3,
                label: 'You',
                icon: AppIcons.navYou,
                selectedIcon: AppIcons.navYouSelected,
                shell: shell,
                spotlightKey: _youKey,
              ),
            ],
          ),
        ),
          ),
          if (_walkthroughVisible)
            Positioned.fill(
              child: WalkthroughScrim(
                steps: _walkthroughSteps(),
                onDismiss: _finishWalkthrough,
              ),
            ),
        ],
      ),
      ),
    );
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
    this.spotlightKey,
  });

  final int index;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final StatefulNavigationShell shell;
  final int badgeCount;

  /// The orientation-tour spotlight anchor for this pillar (see `HomeShell`).
  /// Attached to the icon+label box so the coach mark frames the whole item.
  final GlobalKey? spotlightKey;

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
          key: spotlightKey,
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
