import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_lock_store.dart';
import '../data/device_auth.dart';
import '../data/secure_window.dart';
import 'app_lock_controller.dart';

final appLockStoreProvider =
    Provider<AppLockStore>((ref) => const SharedPrefsAppLockStore());

final deviceAuthProvider = Provider<DeviceAuth>((ref) => LocalDeviceAuth());

final secureWindowProvider =
    Provider<SecureWindow>((ref) => const PlatformSecureWindow());

/// The persisted setting, read in `main()` BEFORE `runApp`.
///
/// It has to be known synchronously by the time the first frame builds: an
/// async read would mean a frame where the answer is unknown, and neither
/// choice for that frame is acceptable — assume unlocked and the schedule
/// flashes past the lock, assume locked and every user without the lock sees a
/// lock screen blink on every launch. Reading one boolean before `runApp` costs
/// a few milliseconds and removes the question.
///
/// Overridden in `main()`; reading it without that override is a programming
/// error, hence the throw rather than a default.
final appLockInitiallyEnabledProvider = Provider<bool>((ref) {
  throw StateError(
    'appLockInitiallyEnabledProvider must be overridden in main() with the '
    'value read from AppLockStore before runApp',
  );
});

final appLockControllerProvider = Provider<AppLockController>((ref) {
  final controller = AppLockController(
    store: ref.watch(appLockStoreProvider),
    auth: ref.watch(deviceAuthProvider),
    secureWindow: ref.watch(secureWindowProvider),
    initiallyEnabled: ref.watch(appLockInitiallyEnabledProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
