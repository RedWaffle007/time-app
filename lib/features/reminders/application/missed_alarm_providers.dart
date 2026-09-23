import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../data/alarm_lifecycle_store.dart';
import 'alarm_timeline_providers.dart';
import 'missed_alarm_service.dart';

final alarmLifecycleStoreProvider = Provider<AlarmLifecycleStore>((ref) {
  return const PlatformAlarmLifecycleStore();
});

final alarmKeyEventsProvider = Provider<AlarmKeyEvents>((ref) {
  return const PlatformAlarmKeyEvents();
});

final missedAlarmServiceProvider = Provider<MissedAlarmService>((ref) {
  final store = ref.watch(alarmLifecycleStoreProvider);
  final service = MissedAlarmService(
    store: store,
    outcomes: ScheduleMissedAlarmOutcomeRepository(
      ref.watch(scheduleRepositoryProvider),
    ),
    timeline: ref.watch(alarmTimelineRepositoryProvider),
    notifier: ref.watch(notificationEventNotifierProvider),
  );
  store.listen(service.resync);
  ref.onDispose(() {
    store.listen(null);
    service.dispose();
  });
  return service;
});

/// Native timeout events are reconciled whenever the target's record changes.
final missedAlarmSyncProvider = Provider<void>((ref) {
  final service = ref.watch(missedAlarmServiceProvider);
  ref.listen(allItemsAsTargetProvider, (_, next) {
    final items = next.value;
    if (items != null) {
      unawaited(service.sync(items, ref.read(currentUidProvider)));
    }
  }, fireImmediately: true);
});
