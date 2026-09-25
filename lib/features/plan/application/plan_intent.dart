import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The three Plan sub-tabs, in the locked order (My Schedule first = the landing
/// sub-tab; DECISIONS.md). The index IS the `TabController` index.
enum PlanTab { mySchedule, activity, groups }

/// A one-shot instruction for the Plan shell: which sub-tab to show, and/or
/// which item to single out on My Schedule.
///
/// [seq] increases on every set, so an identical repeat still notifies — tapping
/// the same reminder twice re-highlights its card rather than being swallowed.
class PlanIntent {
  const PlanIntent({
    this.tab,
    this.itemId,
    this.activityItemId,
    required this.seq,
  });

  /// Sub-tab to open on. Ignored when [itemId] is set (a highlight forces My
  /// Schedule).
  final PlanTab? tab;

  /// The item to scroll to and outline on My Schedule.
  final String? itemId;

  /// The item to scroll to and outline on Activity (planner side).
  final String? activityItemId;

  final int seq;
}

/// **The deterministic replacement for reacting to `/plan?...` query params.**
///
/// go_router caches the Plan branch's root page, so a query-only change to
/// `/plan` does NOT reliably re-run the builder or fire a location notification
/// — the intermittent "sub-tab doesn't switch / no outline" behaviour found on
/// the S5 device pass. Instead, a call site sets this intent immediately BEFORE
/// `go(Routes.plan)`, and the shell listens to it via Riverpod, which notifies
/// deterministically every time. See [PlanShell].
class PlanIntentNotifier extends Notifier<PlanIntent?> {
  int _seq = 0;

  @override
  PlanIntent? build() => null;

  /// Open My Schedule with [itemId] scrolled-to and outlined.
  void highlightItem(String itemId) =>
      state = PlanIntent(itemId: itemId, seq: ++_seq);

  /// Open Activity with [itemId] scrolled-to and outlined — Calendar's
  /// "Open in Activity" lands on the exact plan, not just the tab.
  void highlightActivityItem(String itemId) => state = PlanIntent(
    tab: PlanTab.activity,
    activityItemId: itemId,
    seq: ++_seq,
  );

  /// Open a specific sub-tab (no highlight).
  void openTab(PlanTab tab) => state = PlanIntent(tab: tab, seq: ++_seq);
}

final planIntentProvider = NotifierProvider<PlanIntentNotifier, PlanIntent?>(
  PlanIntentNotifier.new,
);
