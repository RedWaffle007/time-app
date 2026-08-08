import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/widgets/warning_panel.dart';
import '../application/app_lock_controller.dart';
import '../application/app_lock_providers.dart';

/// The app-lock switch, and — when the request was refused — the reason.
///
/// Lives in the applock feature rather than inside the profile screen that hosts
/// it, for one concrete reason: **the refusal path has to be demonstrable.** The
/// case that matters most is a device with no enrolled biometric AND no
/// PIN/pattern/password, where enabling the lock would build a lock with no key.
/// A private widget nested in a Firebase-backed form cannot be pumped in a test,
/// so it would only ever be checked by hand on one device. Here it can be shown.
///
/// It owns its own busy state, so the host screen mounts it and nothing else.
class AppLockTile extends ConsumerStatefulWidget {
  const AppLockTile({super.key});

  @override
  ConsumerState<AppLockTile> createState() => _AppLockTileState();
}

class _AppLockTileState extends ConsumerState<AppLockTile> {
  /// True while [AppLockController.setEnabled] is in flight. The switch is a
  /// round-trip to the platform, so without this a double-tap queues two
  /// conflicting requests.
  bool _busy = false;

  /// Held in a field so [dispose] can reach the controller. `ref.read` throws
  /// once the element is unmounted — the controller itself is app-scoped and
  /// outlives this widget, so keeping the reference is safe and reading `ref`
  /// on the way out is not.
  AppLockController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = ref.read(appLockControllerProvider);
  }

  @override
  void dispose() {
    // The notice is one-shot and the controller is app-scoped, so leaving has to
    // clear it — otherwise a refusal explained here reappears the next time
    // anyone opens the form, long after the user dealt with it.
    _controller?.consumeNotice();
    super.dispose();
  }

  Future<void> _setEnabled(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    final controller = ref.read(appLockControllerProvider);
    // Clear any previous refusal first, so the panel that appears belongs to
    // THIS attempt and a stale one never reads as a fresh failure.
    controller.consumeNotice();
    try {
      await controller.setEnabled(value);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // `appLockControllerProvider` is a plain Provider holding a ChangeNotifier,
    // so `ref.watch` hands back the same instance and never rebuilds. The
    // ListenableBuilder is what makes the switch and the notice follow it.
    final controller = ref.watch(appLockControllerProvider);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Require unlock to open time-app'),
              subtitle: const Text(
                'Ask for your fingerprint, face or device PIN when you open the '
                'app. Also hides the app from the recents switcher and blocks '
                'screenshots.',
              ),
              secondary: const Icon(AppIcons.appLock),
              // The switch reads the CONTROLLER, never local state. A refused
              // request changes nothing, so the switch stays visibly off — the
              // user is never shown a lock that did not actually turn on.
              value: controller.isEnabled,
              onChanged: _busy ? null : _setEnabled,
            ),
            // The refuse-and-explain path, on screen. Reached when the device
            // has no enrolled biometric and no PIN/pattern/password: enabling
            // there would build a lock with no key, so the controller declines
            // and says why, here, next to the switch that would not move.
            //
            // The same panel carries the other direction — the lock turning
            // ITSELF off because the user removed their screen lock while it was
            // on. Both are cases where the app changed its mind about a security
            // setting, and neither may happen silently.
            if (controller.notice case final notice?) WarningPanel(notice),
          ],
        );
      },
    );
  }
}
