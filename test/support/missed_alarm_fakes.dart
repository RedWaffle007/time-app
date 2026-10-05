import 'package:flutter_riverpod/misc.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/reminders/application/missed_alarm_providers.dart';
import 'package:time_app/features/reminders/application/missed_alarm_service.dart';
import 'package:time_app/features/reminders/data/alarm_lifecycle_store.dart';
import 'package:time_app/features/reminders/data/alarm_timeline_repository.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// Nothing missed and no Firebase behind it, for screen tests that show the
/// 🔔 Missed button (2026-10-05): a missed-alarm service with no events, and
/// no target items for it to count.
List<Override> noMissedAlarms() => missedAlarmsWith(const []);

/// The same, with [items] as the signed-in person's target items.
List<Override> missedAlarmsWith(List<ScheduleItem> items) => [
  missedAlarmServiceProvider.overrideWithValue(
    MissedAlarmService(
      store: _NoEvents(),
      outcomes: _Unused(),
      timeline: _UnusedTimeline(),
      notifier: _UnusedNotifier(),
    ),
  ),
  allItemsAsTargetProvider.overrideWith((ref) => Stream.value(items)),
];

class _NoEvents implements AlarmLifecycleStore {
  @override
  Future<List<AlarmLifecycleEvent>> read() async => const [];

  @override
  void listen(Future<void> Function()? onChanged) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Unused implements MissedAlarmOutcomeRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedTimeline implements AlarmTimelineRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedNotifier implements NotificationEventNotifier {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
