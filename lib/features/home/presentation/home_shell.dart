import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../routing/app_router.dart';
import '../../plan_requests/application/plan_request_providers.dart';
import '../../voice/application/voice_parsers.dart';
import '../../voice/presentation/plan_target_picker.dart';
import '../../voice/presentation/voice_capture_sheet.dart';
import '../../walkthrough/application/walkthrough_providers.dart';
import '../../walkthrough/presentation/walkthrough_overlay.dart';
import '../../invites/presentation/pending_invite_listener.dart';

/// The app home: the five-PILLAR bottom bar with the docked centre voice FAB
/// (redesign slice S5; UI-RULES.md §6.12).
///
/// `[ Plan · Request · ⊕ voice · Stats · You ]`. The four pillars are branches
/// of the [StatefulNavigationShell]; the ⊕ is NOT a branch but a docked FAB that
/// starts the voice Plan flow (Track Time and its voice choice were
/// removed 2026-09-27, Batch G item 8; Request took Track's slot). The old three delegation stances (Groups / My Schedule /
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

  // --- first-run orientation tour (S-walkthrough) -------------------------
  //
  // The coach-mark targets: the four pillars and the docked voice FAB. Keys are
  // owned here (not by the buttons) so the overlay can spotlight each. The bar
  // is persistent, so these are always laid out — the tour reads their rects
  // directly.
  final _planKey = GlobalKey();
  final _requestKey = GlobalKey();
  final _voiceKey = GlobalKey();
  final _statsKey = GlobalKey();
  final _youKey = GlobalKey();

  bool _walkthroughVisible = false;

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
          targetKey: _voiceKey,
          spotlightRadius: Radii.pill,
        ),
        WalkthroughStep(
          copy: kWalkthroughStepCopy[3],
          targetKey: _statsKey,
          spotlightRadius: Radii.md,
        ),
        WalkthroughStep(
          copy: kWalkthroughStepCopy[4],
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
        // ONE FAB, always (§6.12): the docked centre voice affordance. Sage,
        // circular, a gentle floating shadow — inviting, not shouting.
        floatingActionButton: FloatingActionButton(
          key: _voiceKey,
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
              // The gap the notch + FAB occupy.
              const SizedBox(width: Sizes.touchTarget),
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

  /// The voice FAB (§6.12) starts the voice Plan flow directly — the old
  /// two-choice sheet went with Track Time (item 8).
  Future<void> _showVoiceSheet() => _voicePlan();

  /// Voice "Plan time" (S6): pick the target FIRST (the person-picker), then
  /// speak "Please give alarm details", parse "[Day][Time][Alarm name]", and
  /// push the schedule-builder with the target chosen and the details filled for
  /// confirm/edit. A dismissal/denial/misparse still opens the builder against
  /// the chosen target — the manual flow — so voice is never the only way.
  Future<void> _voicePlan() async {
    final target = await showPlanTargetPicker(context, ref);
    if (!mounted || target == null) return;

    final outcome = await showVoiceCaptureSheet(
      context,
      ref,
      promptText: 'Please give alarm details',
      hintText: 'Say the day, time and name, '
          'e.g. "Monday 7am gym" or "30 Aug 9pm study".',
    );
    if (!mounted) return;

    PlanDraft? draft;
    if (outcome?.transcript != null) {
      draft = parsePlanUtterance(outcome!.transcript!, now: DateTime.now());
    }

    context.push(Routes.scheduleBuilderVoice(
      targetUid: target.uid,
      isSelf: target.isSelf,
      groupId: target.groupId,
      title: draft?.title,
      date: draft?.date,
      time: draft?.time,
    ));
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
