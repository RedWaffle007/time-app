import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../data/alarm_timeline_repository.dart';
import 'alarm_timeline_service.dart';
import 'dismiss_notifying_timeline.dart';
import 'reminder_providers.dart';

final alarmTimelineRepositoryProvider = Provider<AlarmTimelineRepository>((
  ref,
) {
  return DismissNotifyingTimelineRepository(
    FirestoreAlarmTimelineRepository(FirebaseFirestore.instance),
    ref.watch(notificationEventNotifierProvider),
  );
});

final alarmTimelineServiceProvider = Provider<AlarmTimelineService>((ref) {
  return AlarmTimelineService(
    repository: ref.watch(alarmTimelineRepositoryProvider),
    audit: ref.watch(reminderAuditLogProvider),
  );
});

/// Stream-driven backfill from native fire records to shared item state.
final alarmTimelineSyncProvider = Provider<void>((ref) {
  final service = ref.watch(alarmTimelineServiceProvider);
  ref.listen(allItemsAsTargetProvider, (_, next) {
    final items = next.value;
    if (items != null) {
      unawaited(service.sync(items, ref.read(currentUidProvider)));
    }
  }, fireImmediately: true);
});
