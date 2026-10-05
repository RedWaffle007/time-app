import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/reminders/application/missed_alarms.dart';
import 'package:time_app/features/reminders/application/reminder_policy.dart';
import 'package:time_app/features/reminders/application/reminder_reconciler.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// The Missed list (2026-10-05): which alarms wait for an answer, in what
/// order, and that answering one stops its repeats.
void main() {
  final now = DateTime.utc(2030, 1, 1, 12);

  ScheduleItem item(
    String id, {
    Duration ago = const Duration(minutes: 5),
    bool voice = false,
    String createdBy = 'planner',
    ScheduleItemStatus status = ScheduleItemStatus.approved,
    ScheduleOutcome? outcome,
    ScheduleAlarmTimeline? alarm,
  }) => ScheduleItem(
    id: id,
    targetUid: 'me',
    createdByUid: createdBy,
    groupId: '',
    title: 'Task $id',
    localWallTime: '',
    timezone: 'Etc/UTC',
    scheduledInstantUtc: now.subtract(ago),
    status: status,
    outcome: outcome,
    alarm:
        alarm ??
        ScheduleAlarmTimeline(rangAt: now.subtract(ago), ring: 1),
    voiceNote: voice
        ? const VoiceNoteMeta(
            durationMs: 20000,
            sha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            sizeBytes: 9000,
          )
        : null,
  );

  MissedAlarms list(
    List<ScheduleItem> items, {
    Set<String> ringing = const {},
    Set<String> timedOut = const {},
  }) => missedAlarms(
    items: items,
    uid: 'me',
    nowUtc: now,
    ringingIds: ringing,
    timedOutIds: timedOut,
  );

  test('voice notes and default alarms are listed apart, oldest first', () {
    final m = list([
      item('d2', ago: const Duration(minutes: 3)),
      item('v2', voice: true, ago: const Duration(minutes: 2)),
      item('d1', ago: const Duration(minutes: 30)),
      item('v1', voice: true, ago: const Duration(minutes: 40)),
      item('self', createdBy: 'me', ago: const Duration(minutes: 10)),
    ]);
    expect(m.voice.map((i) => i.id), ['v1', 'v2']);
    // Self-plans are default alarms.
    expect(m.alarms.map((i) => i.id), ['d1', 'self', 'd2']);
    expect(m.count, 5);
  });

  test('silenced, waiting for a repeat and ran out are all listed', () {
    final m = list(
      [
        // Silenced or waiting: rang (ring record), unanswered.
        item('rang'),
        // Ran out: the unavailable fact.
        item(
          'out',
          alarm: ScheduleAlarmTimeline(unavailableAt: now),
        ),
        // Ran out, known only to this phone so far.
        item('local', alarm: const ScheduleAlarmTimeline()),
      ],
      timedOut: {'local'},
    );
    // Same planned time: ordered by id, so the order is stable.
    expect(m.alarms.map((i) => i.id), ['local', 'out', 'rang']);
  });

  test('answered, dismissed, not approved, not rung, in the future or '
      'ringing now: not listed', () {
    final m = list(
      [
        item(
          'done',
          outcome: const ScheduleOutcome(result: OutcomeResult.done),
        ),
        item(
          'dismissed',
          alarm: ScheduleAlarmTimeline(rangAt: now, dismissedAt: now),
        ),
        item('withdrawn', status: ScheduleItemStatus.withdrawn),
        item('never-rang', alarm: const ScheduleAlarmTimeline()),
        item('future', ago: const Duration(minutes: -5)),
        item('ringing'),
      ],
      ringing: {'ringing'},
    );
    expect(m.isEmpty, isTrue);
  });

  test('another person\'s plan or nobody signed in: nothing', () {
    expect(
      missedAlarms(items: [item('a')], uid: 'someone-else', nowUtc: now).isEmpty,
      isTrue,
    );
    expect(
      missedAlarms(items: [item('a')], uid: null, nowUtc: now).isEmpty,
      isTrue,
    );
  });

  test('answering one in the pop-up stops its repeats', () {
    final waiting = item('a');
    final armed = reconcileReminders(
      desired: desiredReminders(items: [waiting], uid: 'me', now: now),
      mirror: const [],
      now: now.subtract(const Duration(minutes: 10)),
    );
    // It was armed before it rang; now it is waiting in the Missed list.
    expect(list([waiting]).alarms.single.id, 'a');
    final answered = item(
      'a',
      outcome: const ScheduleOutcome(result: OutcomeResult.done),
    );
    final after = reconcileReminders(
      desired: desiredReminders(items: [answered], uid: 'me', now: now),
      mirror: armed.mirror,
      now: now,
      presentItemIds: {answered.id},
    );
    expect(after.toCancel, [armed.mirror.single.notificationId]);
    expect(list([answered]).isEmpty, isTrue);
  });
}
