import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../routing/notification_routing.dart';
import '../../auth/application/auth_providers.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../data/alarm_sound.dart';
import '../data/local_notifications_reminder_scheduler.dart';
import '../data/reminder_audit_log.dart';
import '../data/reminder_mirror_store.dart';
import '../data/reminder_scheduler.dart';
import 'reminder_policy.dart';
import 'reminder_service.dart';

/// One plugin instance for the whole app. It is not a singleton internally
/// (the package deliberately made it mockable), so two instances would mean two
/// tap callbacks and two channel creations.
final localNotificationsPluginProvider =
    Provider<FlutterLocalNotificationsPlugin>((ref) {
  return FlutterLocalNotificationsPlugin();
});

final reminderAuditLogProvider = Provider<ReminderAuditLog>((ref) {
  return const ReminderAuditLog();
});

/// The wake-lock-backed alarm sound (native `AlarmSoundService`). A provider so
/// the alarm screen can be pumped in a widget test with a fake that records
/// start/stop instead of touching a platform channel.
final alarmSoundProvider = Provider<AlarmSound>((ref) {
  return const PlatformAlarmSound();
});

final reminderMirrorStoreProvider = Provider<ReminderMirrorStore>((ref) {
  return const SharedPrefsReminderMirrorStore();
});

/// The seam's one wiring point. Swapping the Android implementation for an iOS
/// one — or for a fake — is this line and nothing else.
final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  return LocalNotificationsReminderScheduler(
    plugin: ref.watch(localNotificationsPluginProvider),
    audit: ref.watch(reminderAuditLogProvider),
    // Read lazily inside the callback, not captured here: a tap can arrive
    // before the router has ever been built, and reading `routerProvider` at
    // construction time would build the whole router just to create a scheduler.
    onTapItem: (itemId) => ref.read(notificationRouterProvider).openItem(itemId),
  );
});

final reminderPermissionsProvider = Provider<ReminderPermissions>((ref) {
  return LocalNotificationsReminderPermissions(
    ref.watch(localNotificationsPluginProvider),
  );
});

/// Current OS permission state. `autoDispose`-free and deliberately NOT cached
/// across a resume: on the Redmi, SCHEDULE_EXACT_ALARM is revoked by every
/// reinstall and POST_NOTIFICATIONS can be turned off in Settings at any moment,
/// so a stale "granted" is a lie that shows the user no primer and delivers no
/// reminders. Invalidate it on resume — `TimeApp` does.
final reminderPermissionStateProvider =
    FutureProvider<ReminderPermissionState>((ref) {
  return ref.watch(reminderPermissionsProvider).read();
});

final reminderServiceProvider = Provider<ReminderService>((ref) {
  return ReminderService(
    scheduler: ref.watch(reminderSchedulerProvider),
    store: ref.watch(reminderMirrorStoreProvider),
    audit: ref.watch(reminderAuditLogProvider),
  );
});

/// **The wire.** Watching this once keeps the reminder layer alive and driven.
///
/// It listens to the RECORD stream (`allItemsAsTargetProvider`), not the
/// filtered `myItemsAsTargetProvider`. Today the two agree — a live item is
/// unarchivable, so nothing that deserves a reminder is ever hidden — but they
/// agree by coincidence of the current archive rules, and if that ever changed,
/// the filtered view would silently cancel reminders for items the user merely
/// chose not to look at. Reminders are about what is true, not about what is
/// shown.
///
/// `fireImmediately` covers app start; `TimeApp` calls `sync` again on resume.
/// Both are safe because the reconcile is idempotent — the overwhelmingly common
/// pass computes an empty plan and touches no plugin at all.
/// uid → display name for the planners of items about to be reminded, so the
/// alarm can say "Amina planned Walk for you" even when it fires with the app
/// dead. Only those planners are listened to.
final reminderPlannerNamesProvider = Provider<Map<String, String>>((ref) {
  final items = ref.watch(allItemsAsTargetProvider).value ?? const [];
  final uid = ref.watch(currentUidProvider);
  final names = <String, String>{};
  final planners = reminderPlannerUids(
    items,
    uid: uid,
    now: DateTime.now().toUtc(),
  );
  for (final planner in planners) {
    final name = ref.watch(profileByUidProvider(planner)).value?.name.trim();
    if (name != null && name.isNotEmpty) names[planner] = name;
  }
  return names;
});

final reminderSyncProvider = Provider<void>((ref) {
  final service = ref.watch(reminderServiceProvider);
  service.initialize();

  ref.listen(
    allItemsAsTargetProvider,
    (previous, next) {
      final items = next.value;
      if (items == null) return; // loading, or a stream error — leave the OS as-is
      service.sync(
        items: items,
        uid: ref.read(currentUidProvider),
        reason: 'items',
        plannerNames: ref.read(reminderPlannerNamesProvider),
      );
    },
    fireImmediately: true,
  );

  // A planner's name arriving (or changing) re-words the armed alarm.
  // Idempotent: an unchanged sentence is an unchanged fingerprint, so nothing
  // re-arms.
  ref.listen(reminderPlannerNamesProvider, (previous, next) {
    final items = ref.read(allItemsAsTargetProvider).value;
    if (items == null) return;
    service.sync(
      items: items,
      uid: ref.read(currentUidProvider),
      reason: 'planner-names',
      plannerNames: next,
    );
  });

  // Sign-out and account switches. `sync` itself detects the uid change and
  // clears everything, so this only has to make sure it is CALLED — the item
  // stream goes empty on sign-out but a stream that never emits again would
  // otherwise leave the previous user's reminders armed on the device.
  ref.listen(
    currentUidProvider,
    (previous, next) {
      if (previous == next) return;
      service.sync(
        items: const [],
        uid: next,
        reason: next == null ? 'signed-out' : 'account-changed',
      );
    },
  );
});
