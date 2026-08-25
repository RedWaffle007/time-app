import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/oem_info.dart';
import '../../../core/platform/oem_profile.dart';
import '../data/onboarding_store.dart';

/// Where the "flow completed" flag lives. See [OnboardingStore].
final onboardingStoreProvider = Provider<OnboardingStore>((ref) {
  return const SharedPrefsOnboardingStore();
});

/// Reads `Build.MANUFACTURER`. Shared with the reminder permission read, which
/// uses the same source for [ReminderPermissionState.autostartLikelyNeeded].
final oemInfoProvider = Provider<OemInfo>((ref) {
  return const DeviceInfoOemInfo();
});

/// This device's OEM profile — the family and display name onboarding needs for
/// the autostart step's per-OEM copy. The boolean it carries is the same one the
/// permission state exposes; this provider is for the copy, not the decision.
final oemProfileProvider = FutureProvider<OemProfile>((ref) async {
  final manufacturer = await ref.watch(oemInfoProvider).manufacturer();
  return oemProfileFor(manufacturer);
});

/// Whether the first-run permission flow has been completed on this device.
///
/// A plain [FutureProvider] read of the store; [markOnboardingCompleted]
/// re-reads it after writing, so the gate that watches this rebuilds and swaps
/// the flow out for the app.
final onboardingCompletedProvider = FutureProvider<bool>((ref) async {
  return ref.watch(onboardingStoreProvider).isCompleted();
});

/// Mark the flow done and refresh the flag so watchers rebuild. One helper so
/// both the gate and the settings entry point flip the flag the same way. Takes
/// a [WidgetRef] because both callers are widgets.
Future<void> markOnboardingCompleted(WidgetRef ref) async {
  await ref.read(onboardingStoreProvider).markCompleted();
  ref.invalidate(onboardingCompletedProvider);
}
