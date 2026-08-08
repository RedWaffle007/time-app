import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_lock_controller.dart';
import '../application/app_lock_providers.dart';
import 'lock_screen.dart';

/// Wraps the whole app and covers it when locked.
///
/// **This belongs in `MaterialApp.router`'s `builder`, not in `HomeGate` or a
/// route.** `builder` wraps the Router/Navigator itself, so the gate sits ABOVE
/// every route and above the root navigator that `showDialog` pushes onto —
/// pushed screens, dialogs and bottom sheets are all behind it. A gate at
/// `HomeGate` would guard the home screen only and leave every pushed route
/// (Archived, Edit profile, the schedule builder) reachable if the app was
/// backgrounded while one was on top. That is the door this placement closes.
///
/// The child is **overlaid, never replaced.** Swapping it out would dispose the
/// Navigator and lose the user's whole stack on every lock. So the tree stays
/// mounted underneath and three things hold it shut:
///
///   1. an opaque full-bleed [LockScreen] paints over all of it;
///   2. [IgnorePointer] stops touches reaching a widget under the overlay;
///   3. [ExcludeSemantics] keeps a screen reader from reading out the schedule
///      that is sitting behind the lock — an accessibility-shaped hole that an
///      opaque overlay alone does not close.
///
/// Focus is dropped as the lock goes up, so a text field that still holds focus
/// cannot take hardware-keyboard input from behind the cover.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  AppLockController get _controller => ref.read(appLockControllerProvider);

  bool _wasLocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wasLocked = _controller.isLocked;
    // FLAG_SECURE is per-window and dies with the process, so it is re-applied
    // every launch rather than only when the toggle moves.
    _controller.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The controller owns every rule; this method only translates Flutter's
    // lifecycle vocabulary into the three events it understands. `inactive` is
    // deliberately NOT mapped: it fires for the notification shade and for
    // system permission sheets, and treating those as leaving the app would
    // lock people out mid-task.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _controller.didBackground();
      case AppLifecycleState.detached:
        _controller.didDetach();
      case AppLifecycleState.resumed:
        _controller.didForeground();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final locked = _controller.isLocked;

        if (locked && !_wasLocked) {
          // Drop focus on the way up, after this frame so we are not mutating
          // focus during a build.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => FocusManager.instance.primaryFocus?.unfocus(),
          );
        }
        _wasLocked = locked;

        return Stack(
          children: [
            ExcludeSemantics(
              excluding: locked,
              child: IgnorePointer(ignoring: locked, child: widget.child),
            ),
            if (locked)
              const Positioned.fill(child: LockScreen()),
          ],
        );
      },
    );
  }
}
