import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/scheduling/application/item_lapse_policy.dart';
import 'package:time_app/features/scheduling/application/item_lapse_reconciler.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// The reconciler applies the one deadline rule (item 19, 2026-09-26): a plan
/// scheduled just before midnight is not settled at midnight.
class _Repo implements ScheduleRepository {
  final rejected = <String>[];
  final skipped = <(String, String?)>[];

  @override
  Future<void> reject(
    String targetUid,
    String itemId, {
    String? reason,
    ScheduleItem? item,
  }) async => rejected.add(itemId);

  @override
  Future<bool> markSkippedIfUnsettled(
    String targetUid,
    String itemId, {
    required String reason,
    DateTime? atUtc,
    String? announceToPlannerUid,
  }) async {
    skipped.add((itemId, announceToPlannerUid));
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ScheduleItem _item(String id, DateTime utc, ScheduleItemStatus status) =>
    ScheduleItem(
      id: id,
      targetUid: 'TARGET',
      createdByUid: 'PLANNER',
      groupId: '',
      title: 'x',
      localWallTime: '',
      timezone: 'Asia/Karachi',
      scheduledInstantUtc: utc,
      status: status,
    );

void main() {
  setUpAll(tzdata.initializeTimeZones);

  // 26 Aug 23:50 Karachi = 18:50 UTC; local midnight = 19:00 UTC.
  final late = DateTime.utc(2026, 8, 26, 18, 50);
  final morning = DateTime.utc(2026, 8, 26, 4); // 09:00 Karachi
  final midnight = DateTime.utc(2026, 8, 26, 19);

  test('at midnight only the morning items settle; late ones wait', () async {
    final repo = _Repo();
    final result = await ItemLapseReconciler(repo).reconcile(
      targetUid: 'TARGET',
      now: midnight,
      items: [
        _item('late-pending', late, ScheduleItemStatus.pending),
        _item('late-approved', late, ScheduleItemStatus.approved),
        _item('am-pending', morning, ScheduleItemStatus.pending),
        _item('am-approved', morning, ScheduleItemStatus.approved),
      ],
    );
    expect(repo.rejected, ['am-pending']);
    expect(repo.skipped.map((e) => e.$1), ['am-approved']);
    expect(result, (rejected: 1, skipped: 1));
  });

  test('two hours after a 23:50 plan, it settles', () async {
    final repo = _Repo();
    await ItemLapseReconciler(repo).reconcile(
      targetUid: 'TARGET',
      now: late.add(kMinResponseWindow),
      items: [
        _item('late-pending', late, ScheduleItemStatus.pending),
        _item('late-approved', late, ScheduleItemStatus.approved),
      ],
    );
    expect(repo.rejected, ['late-pending']);
    expect(repo.skipped.map((e) => e.$1), ['late-approved']);
  });

  test('an automatic lapse never writes the planner pop-up record', () async {
    // Item 18 records only a person's own Skip; lapses are the Worker's to
    // announce (item 20).
    final repo = _Repo();
    await ItemLapseReconciler(repo).reconcile(
      targetUid: 'TARGET',
      now: midnight.add(const Duration(days: 1)),
      items: [_item('old', morning, ScheduleItemStatus.approved)],
    );
    expect(repo.skipped, [('old', null)]);
  });
}
