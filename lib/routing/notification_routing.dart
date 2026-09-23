import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/plan/application/plan_intent.dart';
import 'app_router.dart';

/// **The one place that decides where a notification tap lands.**
///
/// There are now two sources of taps — the FCM tray/banner (someone else acted
/// on an item of yours) and a local reminder (your own item is due) — and they
/// arrive through completely different plugin callbacks. Without this, each
/// callback would grow its own copy of the routing rules, and the two copies
/// would drift the first time a route moved. `Routes.approvals` and
/// `Routes.plannerActivity` have already moved once, in the Session 3 shell
/// refactor.
///
/// Every destination here is a location INSIDE the tab shell, which is what
/// makes a plain `go()` correct: go_router selects the owning branch and stacks
/// the screen on it, so the nav bar is present and Back behaves. That property
/// is the entire point of the D2/D11 refactor and is easy to lose by pushing.
class NotificationRouter {
  const NotificationRouter(this._ref);

  final Ref _ref;

  /// A local reminder fired — either tapped, or auto-launched full-screen while
  /// the device was locked. Lands on the full-screen alarm, which silences the
  /// looping tone on Dismiss and then routes into My Schedule (Done / Skip). One
  /// destination for both entry paths keeps the routing decision in one place.
  void openItem(String itemId) {
    if (itemId.isEmpty) return;
    _ref.read(routerProvider).go(Routes.alarmForItem(itemId));
  }

  /// A push from the Worker. Routes by the event's AUDIENCE: target-facing
  /// events (a plan created for you, or withdrawn) open your pending queue
  /// (`/plan/approvals`); planner-facing ones (your plan was decided, or its
  /// outcome recorded) open the Plan shell's Activity sub-tab
  /// (`/plan?tab=activity`). `type == 'outcome'` is the legacy payload, kept
  /// working. Both were `/outcome/…` and `/activity` before the S5 cutover.
  void openForPushEvent(Map<String, dynamic> data) {
    final router = _ref.read(routerProvider);
    switch (data['event']) {
      case 'created':
      case 'withdrawn':
        router.go(Routes.approvals);
      case 'decided':
      case 'outcome':
        _openPlanActivity();
      // Friend-graph pushes: a new request opens the requests inbox; an accept
      // opens the friends list, where the new friend now appears.
      case 'friendRequest':
        router.go(Routes.friendRequests);
      case 'friendAccept':
        router.go(Routes.friends);
      case 'inactivity':
        router.go(Routes.plan);
      default:
        if (data['type'] == 'outcome') {
          _openPlanActivity();
        }
    }
  }

  /// Open the Plan pillar on its Activity sub-tab. Sets the intent BEFORE `go`,
  /// the deterministic signal the Plan shell listens to.
  void _openPlanActivity() {
    _ref.read(planIntentProvider.notifier).openTab(PlanTab.activity);
    _ref.read(routerProvider).go(Routes.plan);
  }
}

final notificationRouterProvider = Provider<NotificationRouter>(
  NotificationRouter.new,
);
