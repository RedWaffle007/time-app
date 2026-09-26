import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/status_style.dart';
import '../../../routing/app_router.dart';
import '../../groups/presentation/groups_screen.dart';
import '../../outcomes/presentation/outcome_screen.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/presentation/planner_activity_screen.dart';
import '../application/plan_intent.dart';

/// **The Plan pillar** (redesign slice S4) — the delegation hub that collapses
/// the three old stance tabs (My Schedule / Activity / Groups) into ONE branch
/// with a swipeable, keep-alive inner TabBar. Landing sub-tab is My Schedule
/// (UI-RULES.md §6.12; DECISIONS.md "UI redesign — Hearth + Candidate A").
///
/// **This is S4 ONLY, not the S5 bar cutover.** The old three-tab bottom bar is
/// untouched and shippable; this shell is reachable *only* behind a temporary
/// account-popup door ("Plan (preview)" → `/plan`), pushed at the root, so it
/// can be walked in isolation. S4 and S5 release together (option a) but are
/// built and reviewed as separate slices.
///
/// ## Keep-alive — reproducing what `StatefulShellBranch` gave us
///
/// The property to preserve is: switching sub-tabs must not drop live Firestore
/// listeners, scroll position, or selection. Two independent mechanisms, so the
/// swipeable [TabBarView] (which the old always-built `IndexedStack` could not
/// offer) costs us nothing:
///
///  1. **Widget-state survival.** Each page is wrapped in [_KeepAlivePage]
///     (`AutomaticKeepAliveClientMixin`, `wantKeepAlive => true`), so the
///     `TabBarView`'s underlying `PageView` keeps each page's element subtree
///     mounted once built instead of disposing it off-screen. Scroll offsets and
///     local state (e.g. [OutcomeScreen]'s highlight timer) therefore survive a
///     swipe — the swipe-compatible equivalent of the old `IndexedStack`.
///  2. **Listener liveness is independent of mounting.** The three feeds are
///     non-`autoDispose` Riverpod providers, so their Firestore subscriptions
///     stay live regardless of whether any widget watches them. A `TabBarView`
///     builds a page lazily on first visit; that is immaterial because liveness
///     never depended on the mount — the keep-alive is purely for widget state.
///
/// Each sub-tab keeps its own actions, surfaced on the shell's ONE app bar and
/// swapped by the active index. The manual-create action is the always-present
/// bottom-right `PLAN` button; the sub-tabs render *embedded* (their own app
/// bars and FABs suppressed).
class PlanShell extends ConsumerStatefulWidget {
  const PlanShell({super.key});

  @override
  ConsumerState<PlanShell> createState() => _PlanShellState();
}

class _PlanShellState extends ConsumerState<PlanShell>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _mySchedule = 0;
  static const _groups = 2;

  /// The item currently forwarded to the embedded My Schedule sub-tab for
  /// highlighting, and the intent seq that carried it — passed as the
  /// re-trigger token so a repeat of the SAME item still re-highlights.
  String? _highlightItemId;
  int _highlightSeq = 0;

  /// The same, for the Activity sub-tab (Calendar → "Open in Activity").
  String? _activityHighlightId;
  int _activityHighlightSeq = 0;

  /// The [PlanIntent.seq] of the last intent applied, so the same intent is not
  /// applied twice (once from the initial [initState] read and again from the
  /// first [ref.listen] fire).
  int _appliedSeq = -1;

  @override
  void initState() {
    super.initState();
    // A pending intent may already be set (a call site did `highlightItem(...)`
    // then `go(Routes.plan)`, building this shell) — apply it to the initial tab
    // and highlight. Warm changes arrive via `ref.listen` in [build].
    final intent = ref.read(planIntentProvider);
    var initialIndex = _mySchedule;
    if (intent != null) {
      _appliedSeq = intent.seq;
      _highlightItemId = intent.itemId;
      _highlightSeq = intent.seq;
      _activityHighlightId = intent.activityItemId;
      _activityHighlightSeq = intent.seq;
      initialIndex = intent.itemId != null
          ? _mySchedule
          : (intent.tab?.index ?? _mySchedule);
    }
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: initialIndex,
    );
    // App-bar actions depend on the active sub-tab, so rebuild when it settles.
    // Guarded to the settle only (`!indexIsChanging`) so a drag does not storm
    // setState every frame.
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
  }

  /// Steer the inner TabBar and/or the highlight to match a [PlanIntent]. A
  /// highlight wins over a `tab` (it forces My Schedule).
  void _applyIntent(PlanIntent intent) {
    if (intent.itemId != null) {
      _tabController.animateTo(_mySchedule);
      setState(() {
        _highlightItemId = intent.itemId;
        _highlightSeq = intent.seq;
      });
    } else if (intent.tab != null) {
      _tabController.animateTo(intent.tab!.index);
      if (intent.activityItemId != null) {
        setState(() {
          _activityHighlightId = intent.activityItemId;
          _activityHighlightSeq = intent.seq;
        });
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // React to deep-link intents deterministically (the WARM path): a call site
    // set a `PlanIntent` right before `go(Routes.plan)`. Riverpod notifies every
    // time — no dependence on go_router re-running this builder — which fixes the
    // intermittent "sub-tab doesn't switch / no outline" behaviour. The seq guard
    // avoids re-applying the intent `initState` already handled.
    ref.listen<PlanIntent?>(planIntentProvider, (_, next) {
      if (next != null && next.seq != _appliedSeq) {
        _appliedSeq = next.seq;
        _applyIntent(next);
      }
    });

    // The Plan aggregate attention count — a documented sum; today it equals the
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan'),
        actions: _actionsFor(_tabController.index),
        bottom: TabBar(
          controller: _tabController,
          // §6.12: understated text tabs, soft sage underline (from the central
          // `tabBarTheme`), swipeable. No fill.
          tabs: [
            // No badge here: the pending count belongs on the Pending
            // approvals icon, the control that resolves it (2026-09-26).
            const Tab(text: 'My Schedule'),
            const Tab(text: 'Activity'),
            const Tab(text: 'Groups'),
          ],
        ),
      ),
      // The one always-present manual create affordance for Plan — a
      // bottom-LEFT text FAB, shown on ALL three sub-tabs (My Schedule /
      // Activity / Groups). Left, not right: on the right it sat over the last
      // card's Done button (device report 2026-09-25). The explicit verb distinguishes it from the centre
      // voice FAB and leaves Track's separate `＋` log-time action unchanged.
      // Its own heroTag prevents a collision with the voice FAB during a route
      // transition.
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'planCreateFab',
        tooltip: 'Plan an item',
        onPressed: () => context.push('${Routes.plan}/schedule-builder'),
        label: Text(
          'PLAN',
          style: context.text.labelLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        // Order matches the tabs above. Each wrapped so its state survives a
        // swipe (see the class doc). `embedded: true` suppresses each screen's
        // own app bar + FAB; the shell provides them. The My Schedule child
        // takes the deep-link `highlightItemId` — kept alive, so its own
        // didUpdateWidget handles a highlight that arrives after first build.
        children: [
          _KeepAlivePage(
            child: OutcomeScreen(
              embedded: true,
              highlightItemId: _highlightItemId,
              highlightToken: _highlightSeq,
            ),
          ),
          _KeepAlivePage(
            child: PlannerActivityScreen(
              embedded: true,
              highlightItemId: _activityHighlightId,
              highlightToken: _activityHighlightSeq,
            ),
          ),
          const _KeepAlivePage(child: GroupsScreen(embedded: true)),
        ],
      ),
    );
  }

  /// The app-bar actions for the active sub-tab, followed by the overflow that
  /// houses Archived. Calendar now lives beside Upcoming Plans in My Schedule.
  /// Detail
  /// pushes target the Plan stack (`/plan/...`) so Back returns to this shell.
  List<Widget> _actionsFor(int index) {
    final contextual = <Widget>[
      switch (index) {
        // The pending count and glow ride THIS icon — the one that opens the
        // queue — from the same provider as the Plan pillar badge.
        _mySchedule => PendingApprovalsAction(
          count: ref.watch(planAttentionCountProvider),
          onPressed: () => context.push('${Routes.plan}/approvals'),
        ),
        // Manual planning lives on the always-present bottom-right PLAN button,
        // so it is not duplicated as an Activity app-bar action.
        _groups => IconButton(
          tooltip: 'New group',
          icon: const Icon(AppIcons.add),
          onPressed: () => showGroupCreateDialog(context, ref),
        ),
        _ => const SizedBox.shrink(),
      },
      // Groups carries a second action (Join by code), like the old screen.
      if (index == _groups)
        IconButton(
          tooltip: 'Join by code',
          icon: const Icon(AppIcons.joinGroup),
          onPressed: () => showGroupJoinDialog(context, ref),
        ),
    ];

    return [
      ...contextual,
      // Archived lives in the Plan overflow per the locked call — it is settled
      // *plan* content, so it does not belong on the identity-only You hub.
      PopupMenuButton<String>(
        icon: const Icon(AppIcons.overflow),
        tooltip: 'More',
        onSelected: (v) {
          if (v == 'archived') context.push(Routes.archived);
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'archived', child: Text('Archived')),
        ],
      ),
    ];
  }
}

/// Keeps its child's element subtree alive while it is off-screen inside a
/// [TabBarView], so scroll position and local state survive a swipe between
/// sub-tabs. See [PlanShell]'s class doc for why this reproduces the old
/// `StatefulShellBranch` behaviour.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by the mixin.
    return widget.child;
  }
}
