import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
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
/// swapped by the active index (§6.12: manual-create is an app-bar `＋`, never a
/// second FAB — the single-FAB rule is reserved for the S5 voice FAB). The
/// sub-tabs render *embedded* (their own app bars and FABs suppressed).
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
      initialIndex = intent.itemId != null
          ? _mySchedule
          : (intent.tab?.index ?? _mySchedule);
    }
    _tabController =
        TabController(length: 3, vsync: this, initialIndex: initialIndex);
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
    // My Schedule pending-approval count (see `planAttentionCountProvider`). It
    // rides the My Schedule sub-tab here and will ride the Plan bottom-bar pillar
    // at S5, from the SAME provider so the two can never disagree.
    final planAttention = ref.watch(planAttentionCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan'),
        actions: _actionsFor(_tabController.index),
        bottom: TabBar(
          controller: _tabController,
          // §6.12: understated text tabs, soft sage underline (from the central
          // `tabBarTheme`), swipeable. No fill.
          tabs: [
            Tab(
              child: PendingCountBadge(
                count: planAttention,
                child: const Text('My Schedule'),
              ),
            ),
            const Tab(text: 'Activity'),
            const Tab(text: 'Groups'),
          ],
        ),
      ),
      // The one always-present create affordance for Plan — a bottom-right FAB,
      // shown on ALL three sub-tabs (My Schedule / Activity / Groups) so
      // "make a new item" is never hidden behind knowing to switch tabs. It
      // sits above the system nav bar (inner Scaffold, so it clears the shell's
      // bottom bar) and is distinct from the centre voice ⊕ (speak-to-create):
      // this is the manual, WhatsApp-style "＋" create. Its own heroTag so it
      // never collides with the shell's voice FAB during a route transition.
      floatingActionButton: FloatingActionButton(
        heroTag: 'planCreateFab',
        tooltip: 'Plan an item',
        onPressed: () => context.push('${Routes.plan}/schedule-builder'),
        child: const Icon(AppIcons.add),
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
          const _KeepAlivePage(child: PlannerActivityScreen(embedded: true)),
          const _KeepAlivePage(child: GroupsScreen(embedded: true)),
        ],
      ),
    );
  }

  /// The app-bar actions for the active sub-tab, followed by the two constant
  /// Plan actions (Calendar, then the overflow that houses Archived). Detail
  /// pushes target the Plan stack (`/plan/...`) so Back returns to this shell.
  List<Widget> _actionsFor(int index) {
    final contextual = <Widget>[
      switch (index) {
        _mySchedule => IconButton(
            tooltip: 'Pending approvals',
            icon: const Icon(AppIcons.approvals),
            onPressed: () => context.push('${Routes.plan}/approvals'),
          ),
        // "Plan an item" now lives on the always-present bottom-right FAB, so it
        // is no longer duplicated as an Activity app-bar action.
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
      // Calendar is a Plan app-bar action per the locked IA (a lens over all
      // three sub-tabs). Pushed at the root, unchanged.
      IconButton(
        tooltip: 'Calendar',
        icon: const Icon(AppIcons.calendar),
        onPressed: () => context.push(Routes.calendar),
      ),
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
