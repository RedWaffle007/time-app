import 'package:flutter_test/flutter_test.dart';

import 'package:time_app/features/notifications/data/http_group_plan_reporter.dart';
import 'package:time_app/features/scheduling/application/minute_lock_backfill.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// Batch G item 4: plans made before minute locks existed get their minute
/// locked from the target's device, off the item stream.
void main() {
  final now = DateTime.utc(2030, 10, 4, 12);

  ScheduleItem item(
    String id,
    DateTime at, {
    ScheduleItemStatus status = ScheduleItemStatus.approved,
    ScheduleOutcome? outcome,
  }) => ScheduleItem(
    id: id,
    targetUid: 'me',
    createdByUid: 'friend',
    groupId: '',
    title: 'T',
    localWallTime: '',
    timezone: 'UTC',
    scheduledInstantUtc: at,
    status: status,
    outcome: outcome,
  );

  final later = DateTime.utc(2030, 10, 4, 18);
  final earlier = DateTime.utc(2030, 10, 4, 6);

  test('only live plans still ahead need a lock', () {
    final ids = itemsNeedingMinuteLock([
      item('live', later),
      item('pending', later, status: ScheduleItemStatus.pending),
      item('past', earlier),
      item(
        'done',
        later,
        outcome: const ScheduleOutcome(result: OutcomeResult.done),
      ),
      item('cancelled', later, status: ScheduleItemStatus.withdrawn),
    ], now).map((i) => i.id);
    expect(ids, ['live', 'pending']);
  });

  test('locks a free minute, once per session', () async {
    final claimed = <String>[];
    final backfill = MinuteLockBackfill(
      holderOf: (_) async => null,
      claim: (id, _) async => claimed.add(id),
    );
    expect(await backfill.run([item('a', later)], now), {'a'});
    expect(await backfill.run([item('a', later)], now), isEmpty);
    expect(claimed, ['a']);
  });

  test('takes over a lock whose plan is dead; leaves one held by another '
      'live plan, and its own', () async {
    final holders = <DateTime, String>{
      later: 'dead-plan',
      later.add(const Duration(hours: 1)): 'other-live',
      later.add(const Duration(hours: 2)): 'mine',
    };
    final claimed = <String>[];
    final backfill = MinuteLockBackfill(
      holderOf: (at) async => holders[at],
      claim: (id, _) async => claimed.add(id),
    );
    await backfill.run([
      item('a', later),
      item('b', later.add(const Duration(hours: 1))),
      item('other-live', later.add(const Duration(hours: 1))),
      item('mine', later.add(const Duration(hours: 2))),
    ], now);
    expect(claimed, ['a']);
  });

  test('a failure is retried on the next run', () async {
    var fail = true;
    final claimed = <String>[];
    final backfill = MinuteLockBackfill(
      holderOf: (_) async => null,
      claim: (id, _) async {
        if (fail) throw Exception('offline');
        claimed.add(id);
      },
    );
    expect(await backfill.run([item('a', later)], now), isEmpty);
    fail = false;
    expect(await backfill.run([item('a', later)], now), {'a'});
    expect(claimed, ['a']);
  });

  group('Worker answer to groupPlanned', () {
    test('reads the verified busy uids', () {
      expect(
        busyUidsFromWorkerResponse(200, '{"sent":2,"busyUids":["a","b"]}'),
        {'a', 'b'},
      );
      expect(busyUidsFromWorkerResponse(200, '{"busyUids":[]}'), isEmpty);
    });

    test('anything else is "could not be reached"', () {
      expect(busyUidsFromWorkerResponse(403, '{"error":"forbidden"}'), isNull);
      expect(busyUidsFromWorkerResponse(200, 'not json'), isNull);
      expect(busyUidsFromWorkerResponse(200, '{"sent":1}'), isNull);
    });
  });
}
