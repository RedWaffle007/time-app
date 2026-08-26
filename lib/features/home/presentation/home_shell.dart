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
import '../../voice/application/voice_parsers.dart';
import '../../voice/presentation/plan_target_picker.dart';
import '../../voice/presentation/voice_capture_sheet.dart';
import '../../walkthrough/application/walkthrough_providers.dart';
import '../../walkthrough/presentation/walkthrough_overlay.dart';

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

  // --- first-run orientation tour (S-walkthrough) -------------------------
  //
  // The coach-mark targets: the four pillars and the docked voice FAB. Keys are
  // owned here (not by the buttons) so the overlay can spotlight each. The bar
  // is persistent, so these are always laid out — the tour reads their rects
  // directly.
  final _planKey = GlobalKey();
  final _trackKey = GlobalKey();
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
          targetKey: _trackKey,
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
    // The Plan aggregate attention count (redesign S4/S5) — the one always-
    // legitimate orange on the bar (§2.7); renders nothing at zero.
    final planAttention = ref.watch(planAttentionCountProvider);
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

    return PopScope(
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
                badgeCount: planAttention,
                shell: shell,
                spotlightKey: _planKey,
              ),
              _PillarButton(
                index: 1,
                label: 'Track',
                icon: AppIcons.navTrack,
                selectedIcon: AppIcons.navTrackSelected,
                shell: shell,
                spotlightKey: _trackKey,
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
        await _voiceTrack();
      case 'plan':
        await _voicePlan();
    }
  }

  /// Voice "Track time" (S6): speak "What are we logging?", parse the reply into
  /// a task + minutes, and open the log sheet PRE-FILLED for confirm/edit.
  /// Nothing is committed here — the sheet is always the confirm step. Every
  /// branch falls back to the identical manual sheet, so a dismissal, a denial
  /// or a misparse all stay usable by hand.
  Future<void> _voiceTrack() async {
    final outcome = await showVoiceCaptureSheet(
      context,
      ref,
      promptText: 'What are we logging?',
      hintText: 'Say the task and how long — e.g. "walking 30 minutes".',
    );
    if (!mounted) return;
    // Dismissed → do nothing. Type-instead → the empty manual sheet.
    if (outcome == null) return;
    if (outcome.transcript == null) {
      await showLogTimeSheet(context, ref);
      return;
    }
    final draft = parseTrackUtterance(outcome.transcript!);
    await showLogTimeSheet(
      context,
      ref,
      prefillTaskName: draft.taskName.isEmpty ? null : draft.taskName,
      prefillMinutes: draft.minutes,
    );
  }

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
      hintText: 'Say the day, time and name — '
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
