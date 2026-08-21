import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  /// A local reminder fired and the user tapped it. Lands on My Schedule with
  /// the item singled out — the screen that already carries Done and Skip, so
  /// the tap ends one gesture away from closing the loop.
  void openItem(String itemId) {
    if (itemId.isEmpty) return;
    _ref.read(routerProvider).go(Routes.outcomeForItem(itemId));
  }

  /// A push from the Worker. Routes by the event's AUDIENCE: target-facing
  /// events (a plan created for you, or withdrawn) open your pending queue;
  /// planner-facing ones (your plan was decided, or its outcome recorded) open
  /// Activity. `type == 'outcome'` is the legacy payload, kept working.
  void openForPushEvent(Map<String, dynamic> data) {
    final router = _ref.read(routerProvider);
    switch (data['event']) {
      case 'created':
      case 'withdrawn':
        router.go(Routes.approvals);
      case 'decided':
      case 'outcome':
        router.go(Routes.plannerActivity);
      default:
        if (data['type'] == 'outcome') {
          router.go(Routes.plannerActivity);
        }
    }
  }
}

final notificationRouterProvider = Provider<NotificationRouter>(
  NotificationRouter.new,
);
