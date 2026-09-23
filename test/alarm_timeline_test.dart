import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/reminders/application/alarm_timeline_service.dart';
import 'package:time_app/features/reminders/data/alarm_timeline_repository.dart';
import 'package:time_app/features/reminders/data/reminder_audit_log.dart';
import 'package:time_app/features/scheduling/application/planner_item_timeline.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

void main() {
  test('only actual audio fires are parsed and earliest duplicate wins', () {
    const csv = '''epoch_millis,local_time,event,item_id
1000,local,FIRED,item-a
1200,local,AUDIO_FIRED,item-a
1100,local,AUDIO_FIRED,item-a
bad,local,AUDIO_FIRED,item-b
1300,local,TAPPED,item-a
''';
    final events = parseAlarmFireEvents(csv);

    expect(events.length, 1);
    expect(events.single.itemId, 'item-a');
    expect(events.single.rangAtUtc.millisecondsSinceEpoch, 1100);
  });

  test(
    'audit reconciliation records only known missing target events',
    () async {
      final repository = _RecordingRepository();
      final service = AlarmTimelineService(
        repository: repository,
        audit: _FakeAudit('''epoch_millis,local_time,event,item_id
1000,local,AUDIO_FIRED,new
2000,local,AUDIO_FIRED,stored
1400,local,AUDIO_FIRED,replace-fallback
3000,local,AUDIO_FIRED,unknown
'''),
      );
      await service.sync([
        _item(id: 'new'),
        _item(
          id: 'stored',
          alarm: ScheduleAlarmTimeline(
            rangAt: DateTime.fromMillisecondsSinceEpoch(1500, isUtc: true),
          ),
        ),
        _item(
          id: 'replace-fallback',
          alarm: ScheduleAlarmTimeline(
            rangAt: DateTime.fromMillisecondsSinceEpoch(1500, isUtc: true),
          ),
        ),
      ], 'target');

      expect(repository.rang, [
        ('target', 'new', 1000),
        ('target', 'replace-fallback', 1400),
      ]);
    },
  );

  test('timeline shows reached events and keeps final outcome pending', () {
    final item = _item(
      id: 'pending',
      alarm: ScheduleAlarmTimeline(
        rangAt: DateTime.utc(2026, 9, 23, 9),
        dismissedAt: DateTime.utc(2026, 9, 23, 9, 1),
      ),
    );

    final events = plannerTimelineFor(item);
    expect(events.map((event) => event.kind), [
      PlannerTimelineEventKind.scheduled,
      PlannerTimelineEventKind.rang,
      PlannerTimelineEventKind.dismissed,
      PlannerTimelineEventKind.pendingOutcome,
    ]);
    expect(events.last.isPending, isTrue);
  });

  test('done and skipped replace pending with their own timestamp', () {
    final doneAt = DateTime.utc(2026, 9, 23, 10);
    final skippedAt = DateTime.utc(2026, 9, 23, 11);
    final done = plannerTimelineFor(
      _item(
        id: 'done',
        outcome: ScheduleOutcome(
          result: OutcomeResult.done,
          completedAt: doneAt,
        ),
      ),
    );
    final skipped = plannerTimelineFor(
      _item(
        id: 'skipped',
        outcome: ScheduleOutcome(
          result: OutcomeResult.skipped,
          skippedAt: skippedAt,
        ),
      ),
    );

    expect(done.last.kind, PlannerTimelineEventKind.done);
    expect(done.last.atUtc, doneAt);
    expect(skipped.last.kind, PlannerTimelineEventKind.skipped);
    expect(skipped.last.atUtc, skippedAt);
    expect(done.any((event) => event.isPending), isFalse);
    expect(skipped.any((event) => event.isPending), isFalse);
  });

  test('legacy outcome remains reached without inventing a timestamp', () {
    final events = plannerTimelineFor(
      _item(
        id: 'legacy-done',
        outcome: const ScheduleOutcome(result: OutcomeResult.done),
      ),
    );

    expect(events.last.kind, PlannerTimelineEventKind.done);
    expect(events.last.atUtc, isNull);
    expect(events.last.isPending, isFalse);
  });
}

ScheduleItem _item({
  required String id,
  ScheduleAlarmTimeline? alarm,
  ScheduleOutcome? outcome,
}) => ScheduleItem(
  id: id,
  targetUid: 'target',
  createdByUid: 'planner',
  groupId: '',
  title: 'Task',
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: DateTime.utc(2026, 9, 23, 8),
  status: ScheduleItemStatus.approved,
  alarm: alarm,
  outcome: outcome,
);

class _RecordingRepository implements AlarmTimelineRepository {
  final rang = <(String, String, int)>[];

  @override
  Future<void> recordRang(String uid, String itemId, DateTime atUtc) async {
    rang.add((uid, itemId, atUtc.millisecondsSinceEpoch));
  }

  @override
  Future<void> recordDismissed(
    String uid,
    String itemId,
    DateTime atUtc,
  ) async {}
}

class _FakeAudit implements ReminderAuditLog {
  _FakeAudit(this.csv);
  final String csv;

  @override
  Future<String> read() async => csv;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
