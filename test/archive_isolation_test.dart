import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/archive/application/archive_providers.dart';
import 'package:time_app/features/archive/data/archive_repository.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// **Archive must never be able to hide the schedule.**
///
/// The archive read is a join onto My Schedule and Activity. If a failed archive
/// read propagated, `AsyncView` would drop into its error state and a *view
/// convenience* would take down the product — offline, or on any device running
/// before the `users/{uid}/state` rule was deployed. So the isolation is
/// asserted here rather than reasoned about: these tests fail if anyone ever
/// removes the error transformer or swaps `valueOrNull` for a rethrowing read.
///
/// The tests are pure Dart — no Firebase. `currentUidProvider` exists precisely
/// so the uid can be supplied without a `firebase_auth` `User`, and both
/// repositories are behind providers, so the whole join can be exercised with
/// fakes.
void main() {
  ScheduleItem item(String id, {ScheduleItemStatus? status}) => ScheduleItem(
        id: id,
        targetUid: 'me',
        createdByUid: 'planner',
        groupId: 'g1',
        title: 'Item $id',
        localWallTime: '2026-07-26T09:00',
        timezone: 'Europe/London',
        scheduledInstantUtc: DateTime.utc(2026, 7, 26, 8),
        status: status ?? ScheduleItemStatus.approved,
      );

  ProviderContainer harness({
    required ArchiveRepository archive,
    List<ScheduleItem> items = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        currentUidProvider.overrideWithValue('me'),
        archiveRepositoryProvider.overrideWithValue(archive),
        allItemsAsTargetProvider.overrideWith((ref) => Stream.value(items)),
        allItemsAsPlannerProvider.overrideWith((ref) => Stream.value(items)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Waits for the two source streams and the archive stream to settle.
  Future<void> settle(ProviderContainer c) async {
    c.listen(allItemsAsTargetProvider, (_, _) {});
    c.listen(allItemsAsPlannerProvider, (_, _) {});
    c.listen(archivedIdsStreamProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
  }

  group('an archive read failure is isolated', () {
    test('My Schedule still shows every item when the archive read errors',
        () async {
      final c = harness(
        archive: _FailingArchiveRepository(),
        items: [item('a'), item('b')],
      );
      await settle(c);

      final schedule = c.read(myItemsAsTargetProvider);

      expect(schedule.hasError, isFalse,
          reason: 'a broken archive must not error the schedule');
      expect(schedule.value?.map((i) => i.id), ['a', 'b'],
          reason: 'unfilterable archive means nothing is hidden');
    });

    test('Activity still shows every item when the archive read errors',
        () async {
      final c = harness(
        archive: _FailingArchiveRepository(),
        items: [item('a'), item('b')],
      );
      await settle(c);

      final activity = c.read(myItemsAsPlannerProvider);

      expect(activity.hasError, isFalse);
      expect(activity.value?.map((i) => i.id), ['a', 'b']);
    });

    test('the archive provider itself resolves to empty, not to an error',
        () async {
      final c = harness(archive: _FailingArchiveRepository());
      await settle(c);

      expect(c.read(archivedIdsStreamProvider).hasError, isFalse,
          reason: 'the transformer converts the error event into empty data');
      expect(c.read(archivedIdsProvider), isEmpty);
    });

    test('the schedule is readable BEFORE the archive has loaded', () async {
      // The archive never emits — the pre-cache-fill / hung-listener case.
      final c = harness(
        archive: _NeverArchiveRepository(),
        items: [item('a')],
      );
      c.listen(allItemsAsTargetProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);

      final schedule = c.read(myItemsAsTargetProvider);

      expect(schedule.hasError, isFalse);
      expect(schedule.value?.map((i) => i.id), ['a'],
          reason: 'a pending archive read must not gate the schedule');
    });
  });

  group('when the archive DOES load', () {
    test('archived ids are filtered out of both views', () async {
      final c = harness(
        archive: _FixedArchiveRepository({'b'}),
        items: [item('a'), item('b'), item('c')],
      );
      await settle(c);

      expect(c.read(myItemsAsTargetProvider).value?.map((i) => i.id),
          ['a', 'c']);
      expect(c.read(myItemsAsPlannerProvider).value?.map((i) => i.id),
          ['a', 'c']);
    });

    test('the Archived view shows them, deduped across both roles', () async {
      final c = harness(
        archive: _FixedArchiveRepository({'b'}),
        items: [item('a'), item('b')],
      );
      await settle(c);

      // Both source streams carry item 'b' here (the self-planned shape), so a
      // missing dedup would show it twice.
      expect(c.read(archivedItemsProvider).value?.map((i) => i.id), ['b']);
    });
  });

  group('the terminal-state split', () {
    test('live items are hideable by neither route', () {
      for (final live in [
        item('a', status: ScheduleItemStatus.pending),
        item('a', status: ScheduleItemStatus.approved),
      ]) {
        expect(live.isAutoArchived, isFalse);
        expect(live.isManuallyArchivable, isFalse,
            reason: 'hiding a plan you have not answered is the one thing '
                'archive must never allow');
        expect(live.isSettled, isFalse);
      }
    });

    test('rejected / withdrawn are AUTO, never manual', () {
      for (final status in [
        ScheduleItemStatus.rejected,
        ScheduleItemStatus.withdrawn,
        ScheduleItemStatus.cancelled,
      ]) {
        final dead = item('a', status: status);
        expect(dead.isAutoArchived, isTrue);
        expect(dead.isManuallyArchivable, isFalse,
            reason: 'no Archive tap and no Unarchive — rejecting IS the '
                'clearing action, and un-hiding would restore the clutter');
      }
    });

    test('done / skipped are MANUAL, never auto', () {
      expect(_done.isManuallyArchivable, isTrue);
      expect(_done.isAutoArchived, isFalse,
          reason: 'a completed item is not clutter the instant it happens');
    });
  });

  group('auto-archive is a view rule, not a write', () {
    test('rejected and withdrawn are hidden with an EMPTY archive set',
        () async {
      // The archive doc is empty — nothing was ever written for these items,
      // and nothing could have been: the target rejects, but it is the
      // PLANNER's feed that needs clearing, and neither can write to the
      // other's subtree.
      final c = harness(
        archive: _FixedArchiveRepository(const {}),
        items: [
          item('live'),
          item('rejected', status: ScheduleItemStatus.rejected),
          item('withdrawn', status: ScheduleItemStatus.withdrawn),
        ],
      );
      await settle(c);

      expect(c.read(myItemsAsTargetProvider).value?.map((i) => i.id), ['live']);
      expect(c.read(myItemsAsPlannerProvider).value?.map((i) => i.id), ['live']);
    });

    test('they stay hidden even when the archive read is BROKEN', () async {
      // The auto rule reads a field already in hand, so unlike the manual set
      // it degrades to nothing at all — a rejected row cannot reappear because
      // the archive is unreachable.
      final c = harness(
        archive: _FailingArchiveRepository(),
        items: [item('live'), item('rejected', status: ScheduleItemStatus.rejected)],
      );
      await settle(c);

      expect(c.read(myItemsAsTargetProvider).value?.map((i) => i.id), ['live']);
    });

    test('the Archived view lists BOTH routes', () async {
      final c = harness(
        archive: _FixedArchiveRepository({'done'}),
        items: [
          item('live'),
          _done,
          item('rejected', status: ScheduleItemStatus.rejected),
        ],
      );
      await settle(c);

      expect(
        c.read(archivedItemsProvider).value?.map((i) => i.id),
        containsAll(<String>['done', 'rejected']),
        reason: 'a rejected item that appeared nowhere would make its own '
            'record unreachable',
      );
      expect(c.read(archivedItemsProvider).value?.map((i) => i.id),
          isNot(contains('live')));
    });
  });

  group('the record layer is never filtered', () {
    test('rejected and archived items are both still in the raw streams',
        () async {
      // The constraint every future stats/summary consumer depends on. If this
      // ever fails, archived items have started vanishing from the record and
      // the numbers will silently under-count.
      final c = harness(
        archive: _FixedArchiveRepository({'done'}),
        items: [
          item('live'),
          _done,
          item('rejected', status: ScheduleItemStatus.rejected),
        ],
      );
      await settle(c);

      expect(c.read(allItemsAsTargetProvider).value?.map((i) => i.id),
          ['live', 'done', 'rejected']);
      expect(c.read(allItemsAsPlannerProvider).value?.map((i) => i.id),
          ['live', 'done', 'rejected']);
    });
  });
}

/// An approved item with a recorded outcome — the manual-archive case.
final _done = ScheduleItem(
  id: 'done',
  targetUid: 'me',
  createdByUid: 'planner',
  groupId: 'g1',
  title: 'done thing',
  localWallTime: '2026-07-26T09:00',
  timezone: 'Europe/London',
  scheduledInstantUtc: DateTime.utc(2026, 7, 26, 8),
  status: ScheduleItemStatus.approved,
  outcome: const ScheduleOutcome(result: OutcomeResult.done),
);

/// Stands in for a denied read (rules not deployed) or an offline cold start.
class _FailingArchiveRepository implements ArchiveRepository {
  @override
  Stream<Set<String>> watchArchivedIds(String uid) =>
      Stream.error(StateError('PERMISSION_DENIED'));

  @override
  Future<void> archive(String uid, String itemId) async {}

  @override
  Future<void> unarchive(String uid, String itemId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A listener that connects but never emits.
class _NeverArchiveRepository implements ArchiveRepository {
  @override
  Stream<Set<String>> watchArchivedIds(String uid) =>
      const Stream<Set<String>>.empty().asBroadcastStream()
        ..listen(null); // stays open, emits nothing

  @override
  Future<void> archive(String uid, String itemId) async {}

  @override
  Future<void> unarchive(String uid, String itemId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixedArchiveRepository implements ArchiveRepository {
  _FixedArchiveRepository(this.ids);
  final Set<String> ids;

  @override
  Stream<Set<String>> watchArchivedIds(String uid) => Stream.value(ids);

  @override
  Future<void> archive(String uid, String itemId) async {}

  @override
  Future<void> unarchive(String uid, String itemId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
