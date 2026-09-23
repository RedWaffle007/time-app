// The constructor takes named collaborators. Initializing formals would expose
// private names (`_repository:` / `_audit:`) in the public constructor API, so
// the explicit initializer list is intentional.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../scheduling/domain/schedule_item.dart';
import '../data/alarm_timeline_repository.dart';
import '../data/reminder_audit_log.dart';

class AlarmFireEvent {
  const AlarmFireEvent({required this.itemId, required this.rangAtUtc});

  final String itemId;
  final DateTime rangAtUtc;
}

/// Extract actual native audio starts from the diagnostic CSV.
///
/// `FIRED` is the silent audit shadow. Only `AUDIO_FIRED` proves the alarm sound
/// receiver ran, so shadow rows and Dart annotations are deliberately ignored.
List<AlarmFireEvent> parseAlarmFireEvents(String csv) {
  final earliestByItem = <String, DateTime>{};
  for (final line in csv.split('\n').skip(1)) {
    if (line.trim().isEmpty) continue;
    final columns = line.split(',');
    if (columns.length < 4 || columns[2] != 'AUDIO_FIRED') continue;
    final epoch = int.tryParse(columns[0]);
    final itemId = columns[3];
    if (epoch == null || epoch <= 0 || itemId.isEmpty) continue;
    final at = DateTime.fromMillisecondsSinceEpoch(epoch, isUtc: true);
    final previous = earliestByItem[itemId];
    if (previous == null || at.isBefore(previous)) earliestByItem[itemId] = at;
  }
  return [
    for (final entry in earliestByItem.entries)
      AlarmFireEvent(itemId: entry.key, rangAtUtc: entry.value),
  ];
}

/// Moves target-device alarm observations into the shared item timeline.
class AlarmTimelineService {
  AlarmTimelineService({
    required AlarmTimelineRepository repository,
    required ReminderAuditLog audit,
  }) : _repository = repository,
       _audit = audit;

  final AlarmTimelineRepository _repository;
  final ReminderAuditLog _audit;
  Future<void> _queue = Future.value();

  Future<void> sync(List<ScheduleItem> items, String? uid) {
    final next = _queue.then((_) => _sync(items, uid)).catchError((
      Object error,
    ) {
      debugPrint('AlarmTimelineService: sync failed: $error');
    });
    _queue = next;
    return next;
  }

  Future<void> _sync(List<ScheduleItem> items, String? uid) async {
    if (uid == null || items.isEmpty) return;
    final byId = {for (final item in items) item.id: item};
    final events = parseAlarmFireEvents(await _audit.read());
    for (final event in events) {
      final item = byId[event.itemId];
      if (item == null || item.targetUid != uid) continue;
      final stored = item.alarm?.rangAt;
      if (stored != null && !event.rangAtUtc.isBefore(stored)) continue;
      await _repository.recordRang(uid, item.id, event.rangAtUtc);
    }
  }

  Future<void> recordRangFallback(String uid, String itemId) => _bestEffort(
    () => _repository.recordRang(uid, itemId, DateTime.now().toUtc()),
  );

  Future<void> recordDismissed(String uid, String itemId) => _bestEffort(
    () => _repository.recordDismissed(uid, itemId, DateTime.now().toUtc()),
  );

  Future<void> _bestEffort(Future<void> Function() write) async {
    try {
      await write();
    } catch (error) {
      debugPrint('AlarmTimelineService: event write failed: $error');
    }
  }
}
