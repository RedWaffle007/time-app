import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/reminders/application/reminder_policy.dart';
import 'package:time_app/features/reminders/application/reminder_reconciler.dart';
import 'package:time_app/features/reminders/application/reminder_service.dart';
import 'package:time_app/features/reminders/data/reminder_mirror_store.dart';
import 'package:time_app/features/reminders/data/reminder_scheduler.dart';
import 'package:time_app/features/reminders/domain/reminder.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// The reminder layer's correctness lives here rather than on a device, because
/// its failure mode is a reminder that silently never arrives — there is no
/// crash, no red screen and no log line to notice. Everything that decides
/// whether an alarm exists is a pure function precisely so it can be pinned
/// here; the device pass then only has to answer "does the OS honour it", which
/// is the one question a test genuinely cannot.
void main() {
  // The audit log is a MethodChannel; with a binding in place its calls fail as
  // MissingPluginException and are swallowed, which is the intended off-Android
  // behaviour.
  TestWidgetsFlutterBinding.ensureInitialized();

  // Anchored to the REAL clock, not to a hardcoded date.
  //
  // This was `DateTime.utc(2026, 8, 20, 12)` — the day the file was written —
  // and every fixture item sat two hours after it. The pure-function groups
  // below are unaffected either way, because they are handed `now` explicitly.
  // `ReminderService.sync` is not: it reads `DateTime.now()` itself
  // (reminder_service.dart:95), so from 2026-08-21 onwards every fixture was in
  // the PAST, `desiredReminders` filtered them all out, and seven service tests
  // failed with an empty plan. The suite worked for exactly one day.
  //
  // Everything here is relative to `now`, so anchoring it keeps each test's
  // meaning identical and makes it true on every future day.
  //
  // Truncated to whole MILLISECONDS, which is not cosmetic: the durable mirror
  // serialises an instant as `fireAtMs` (reminder_mirror_store.dart), so a
  // microsecond component cannot survive a round trip and the round-trip test
  // below would fail on it. Truncating states the mirror's real precision
  // rather than hiding it behind a fixture that happened to have none.
  final now = DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().millisecondsSinceEpoch,
    isUtc: true,
  );
  DateTime inHours(int h) => now.add(Duration(hours: h));

  ScheduleItem item({
    required String id,
    String targetUid = 'me',
    String createdByUid = 'planner',
    ScheduleItemStatus status = ScheduleItemStatus.approved,
    ScheduleOutcome? outcome,
    DateTime? at,
    String title = 'Run',
    String? note,
  }) =>
      ScheduleItem(
        id: id,
        targetUid: targetUid,
        createdByUid: createdByUid,
        groupId: 'g1',
        title: title,
        note: note,
        localWallTime: '2026-08-20T14:00',
        timezone: 'Asia/Kolkata',
        scheduledInstantUtc: at ?? inHours(2),
        status: status,
        outcome: outcome,
      );

  ReminderRequest request(String id, {DateTime? at, String title = 'Run'}) =>
      ReminderRequest(
        itemId: id,
        fireAtUtc: at ?? inHours(2),
        title: title,
        body: 'b',
      );

  // -------------------------------------------------------------------------
  group('notification ids', () {
    test('are deterministic — the same item id always yields the same id', () {
      // The whole reason the id is a hash rather than a counter: cancelling a
      // notification means reproducing its id exactly, from a cold start, after
      // a reboot, possibly with no mirror at all.
      expect(reminderNotificationId('abc123'), reminderNotificationId('abc123'));
      expect(reminderNotificationId(''), reminderNotificationId(''));
    });

    test('are always a positive 31-bit int', () {
      for (final id in [
        '',
        'a',
        'AbC-9_xyz',
        'yQ8vN2mLpK4rT7wZ1cB0',
        '😀 unicode id',
        'x' * 500,
      ]) {
        final n = reminderNotificationId(id);
        expect(n, greaterThanOrEqualTo(0), reason: id);
        expect(n, lessThanOrEqualTo(0x7FFFFFFF), reason: id);
      }
    });

    test('spread across distinct item ids', () {
      final ids = {
        for (var i = 0; i < 2000; i++) reminderNotificationId('item_$i'),
      };
      // Not a distribution proof — just a guard against a hash that collapses.
      expect(ids.length, 2000);
    });

    test('allocate returns the plain hash when nothing has claimed it', () {
      expect(allocateNotificationId('abc', const {}),
          reminderNotificationId('abc'));
    });

    test('allocate probes past a collision, deterministically', () {
      final base = reminderNotificationId('abc');
      final first = allocateNotificationId('abc', {base});
      expect(first, isNot(base));
      // Same inputs, same answer — two devices must not diverge.
      expect(allocateNotificationId('abc', {base}), first);
      expect(allocateNotificationId('abc', {base, first}),
          isNot(anyOf(base, first)));
    });

    test('allocate stays inside 31 bits even when probing past the top', () {
      // Nothing here can produce a negative id or one Java would reject.
      final taken = {for (var i = 0; i < 5; i++) 0x7FFFFFFF - i};
      final id = allocateNotificationId('anything', taken);
      expect(id, greaterThanOrEqualTo(0));
      expect(id, lessThanOrEqualTo(0x7FFFFFFF));
    });
  });

  // -------------------------------------------------------------------------
  group('desiredReminders — which items get a reminder at all', () {
    test('an approved, un-acted, future item for me is reminded', () {
      final d = desiredReminders(
        items: [item(id: 'a')],
        uid: 'me',
        now: now,
      );
      expect(d.map((r) => r.itemId), ['a']);
      expect(d.single.fireAtUtc, inHours(2));
      expect(d.single.title, 'Run');
    });

    test('a PENDING item is not reminded — consent is the premise', () {
      // Alarming someone about a plan they have not agreed to is the exact
      // imposition the consent model exists to prevent.
      expect(
        desiredReminders(
          items: [item(id: 'a', status: ScheduleItemStatus.pending)],
          uid: 'me',
          now: now,
        ),
        isEmpty,
      );
    });

    test('rejected, withdrawn and cancelled items are not reminded', () {
      for (final s in [
        ScheduleItemStatus.rejected,
        ScheduleItemStatus.withdrawn,
        ScheduleItemStatus.cancelled,
      ]) {
        expect(
          desiredReminders(
            items: [item(id: 'a', status: s)],
            uid: 'me',
            now: now,
          ),
          isEmpty,
          reason: s.name,
        );
      }
    });

    test('an item with a recorded outcome is not reminded', () {
      for (final r in OutcomeResult.values) {
        expect(
          desiredReminders(
            items: [item(id: 'a', outcome: ScheduleOutcome(result: r))],
            uid: 'me',
            now: now,
          ),
          isEmpty,
          reason: r.name,
        );
      }
    });

    test('a past item is not reminded, including exactly now', () {
      expect(
        desiredReminders(
          items: [item(id: 'a', at: inHours(-1)), item(id: 'b', at: now)],
          uid: 'me',
          now: now,
        ),
        isEmpty,
      );
    });

    test('an item I merely PLANNED for someone else is not reminded to me', () {
      // The planner gets the outcome push, not an alarm on their own phone.
      expect(
        desiredReminders(
          items: [item(id: 'a', targetUid: 'someone-else')],
          uid: 'me',
          now: now,
        ),
        isEmpty,
      );
    });

    test('a self-planned item IS reminded — creator and target are the same', () {
      expect(
        desiredReminders(
          items: [item(id: 'a', createdByUid: 'me')],
          uid: 'me',
          now: now,
        ),
        hasLength(1),
      );
    });

    test('nobody signed in means nothing scheduled', () {
      expect(
        desiredReminders(items: [item(id: 'a')], uid: null, now: now),
        isEmpty,
      );
    });

    test('the body carries the planner note, or a fallback', () {
      expect(reminderBody(item(id: 'a', note: 'bring shoes')), 'bring shoes');
      expect(reminderBody(item(id: 'a', note: '   ')),
          'Tap to mark it done or skip.');
      expect(reminderBody(item(id: 'a')), 'Tap to mark it done or skip.');
    });

    test('the body never renders a date — locale formatting needs a context', () {
      // Guards the standing worldwide requirement: any date/time rendering has
      // to go through core/format/datetime_format.dart, which a scheduler
      // cannot reach. The body must therefore contain no formatted time.
      final body = reminderBody(item(id: 'a'));
      expect(body, isNot(contains('2026')));
      expect(body, isNot(matches(RegExp(r'\d{1,2}:\d{2}'))));
    });
  });

  // -------------------------------------------------------------------------
  group('reconcileReminders', () {
    test('schedules everything on a cold first run', () {
      final plan = reconcileReminders(
        desired: [request('a'), request('b')],
        mirror: const [],
        now: now,
      );
      expect(plan.toSchedule.map((s) => s.request.itemId), ['a', 'b']);
      expect(plan.toCancel, isEmpty);
      expect(plan.mirror, hasLength(2));
    });

    test('IS IDEMPOTENT — re-running against its own result does nothing', () {
      // The property the whole design rests on: this runs on every item
      // emission, every app start and every resume, so the common pass has to
      // be free and side-effect-free.
      final first = reconcileReminders(
        desired: [request('a'), request('b')],
        mirror: const [],
        now: now,
      );
      final second = reconcileReminders(
        desired: [request('a'), request('b')],
        mirror: first.mirror,
        now: now,
      );
      expect(second.isEmpty, isTrue);
      expect(second.mirror.map((m) => m.notificationId),
          first.mirror.map((m) => m.notificationId));
    });

    test('a moved time re-schedules under the SAME notification id', () {
      final first = reconcileReminders(
        desired: [request('a')],
        mirror: const [],
        now: now,
      );
      final moved = reconcileReminders(
        desired: [request('a', at: inHours(5))],
        mirror: first.mirror,
        now: now,
      );
      expect(moved.toSchedule, hasLength(1));
      expect(moved.toCancel, isEmpty, reason: 'replacement is by id, not cancel');
      expect(moved.toSchedule.single.notificationId,
          first.mirror.single.notificationId);
      expect(moved.mirror.single.fireAtUtc, inHours(5));
    });

    test('a retitled item re-schedules — the fingerprint is not just the time',
        () {
      final first = reconcileReminders(
        desired: [request('a')],
        mirror: const [],
        now: now,
      );
      final retitled = reconcileReminders(
        desired: [request('a', title: 'Swim')],
        mirror: first.mirror,
        now: now,
      );
      expect(retitled.toSchedule, hasLength(1));
    });

    test('an item that stops being desired is cancelled', () {
      // One rule covering withdraw, reject, done, skip, un-approval and outright
      // deletion: each of them simply stops producing a desired entry.
      final first = reconcileReminders(
        desired: [request('a'), request('b')],
        mirror: const [],
        now: now,
      );
      final gone = reconcileReminders(
        desired: [request('a')],
        mirror: first.mirror,
        now: now,
      );
      expect(gone.toSchedule, isEmpty);
      expect(gone.toCancel, [
        first.mirror.firstWhere((m) => m.itemId == 'b').notificationId,
      ]);
      expect(gone.mirror.map((m) => m.itemId), ['a']);
    });

    test('a desired reminder whose moment has passed is dropped, not armed', () {
      // `zonedSchedule` throws on a past date, and `now` is read before the
      // awaits — so this is the guard that keeps a stale entry from reaching it.
      final plan = reconcileReminders(
        desired: [request('a', at: inHours(-1))],
        mirror: const [],
        now: now,
      );
      expect(plan.toSchedule, isEmpty);
      expect(plan.mirror, isEmpty);
    });

    test('a mirrored reminder that has gone stale is cancelled', () {
      final armed = reconcileReminders(
        desired: [request('a')],
        mirror: const [],
        now: now,
      );
      final later = reconcileReminders(
        desired: [request('a')],
        mirror: armed.mirror,
        // Three hours on, the 2-hour item is in the past.
        now: inHours(3),
      );
      expect(later.toCancel, [armed.mirror.single.notificationId]);
      expect(later.mirror, isEmpty);
    });

    test('a colliding newcomer gets a different id and does NOT displace the '
        'item already holding it', () {
      // The collision story, exercised. `b` is mirrored under exactly the id
      // `a` would prefer; `a` must probe rather than overwrite `b`'s alarm,
      // which would leave `b` silently un-armed.
      final contested = reminderNotificationId('a');
      final mirror = [
        ScheduledReminder(
          itemId: 'b',
          notificationId: contested,
          fireAtUtc: inHours(2),
          fingerprint: request('b').fingerprint,
        ),
      ];

      final plan = reconcileReminders(
        desired: [request('a'), request('b')],
        mirror: mirror,
        now: now,
      );

      final aId = plan.mirror.firstWhere((m) => m.itemId == 'a').notificationId;
      final bId = plan.mirror.firstWhere((m) => m.itemId == 'b').notificationId;
      expect(bId, contested, reason: 'the incumbent keeps its id');
      expect(aId, isNot(contested));
      expect(plan.toSchedule.map((s) => s.request.itemId), ['a']);
      expect(plan.toCancel, isEmpty);
    });

    test('id allocation does not depend on the order items arrive in', () {
      // Firestore snapshot order is not stable; two passes over the same set
      // must not produce two different assignments.
      final forwards = reconcileReminders(
        desired: [request('a'), request('b'), request('c')],
        mirror: const [],
        now: now,
      );
      final backwards = reconcileReminders(
        desired: [request('c'), request('b'), request('a')],
        mirror: const [],
        now: now,
      );
      Map<String, int> byItem(ReminderPlan p) =>
          {for (final m in p.mirror) m.itemId: m.notificationId};
      expect(byItem(forwards), byItem(backwards));
    });
  });

  // -------------------------------------------------------------------------
  group('the durable mirror', () {
    test('round-trips through JSON with the instant intact', () async {
      final store = InMemoryReminderMirrorStore();
      final original = [
        ScheduledReminder(
          itemId: 'a',
          notificationId: 12345,
          fireAtUtc: inHours(2),
          fingerprint: 'fp',
        ),
      ];
      await store.save(original);

      final json = ScheduledReminder.encode(original);
      final decoded = ScheduledReminder.decode(json);
      expect(decoded, hasLength(1));
      expect(decoded.single.itemId, 'a');
      expect(decoded.single.notificationId, 12345);
      expect(decoded.single.fireAtUtc, inHours(2));
      expect(decoded.single.fireAtUtc.isUtc, isTrue);
      expect(decoded.single.fingerprint, 'fp');
    });

    test('a corrupt row is dropped, not thrown — the rest survives', () {
      // Reading the mirror as partially empty re-schedules the missing entries,
      // which is the recoverable direction. Throwing at startup is not.
      const json = '[{"itemId":"a","notificationId":1,"fireAtMs":100,'
          '"fingerprint":"f"},{"itemId":"b"},null,7]';
      final decoded = ScheduledReminder.decode(json);
      expect(decoded.map((r) => r.itemId), ['a']);
    });

    test('unreadable JSON reads as an empty mirror rather than failing', () {
      expect(ScheduledReminder.decode('not json at all'), isEmpty);
      expect(ScheduledReminder.decode('{"not":"a list"}'), isEmpty);
      expect(ScheduledReminder.decode(''), isEmpty);
      expect(ScheduledReminder.decode(null), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('ReminderPermissionState.isFullyReady', () {
    ReminderPermissionState state({
      bool notifications = true,
      bool exact = true,
      bool fsi = true,
    }) =>
        ReminderPermissionState(
          notificationsEnabled: notifications,
          exactAlarmsAllowed: exact,
          fullScreenIntentAllowed: fsi,
        );

    test('needs all three — the primer shows until every one is granted', () {
      expect(state().isFullyReady, isTrue);
      expect(state(notifications: false).isFullyReady, isFalse);
      expect(state(exact: false).isFullyReady, isFalse);
      expect(state(fsi: false).isFullyReady, isFalse,
          reason: 'full-screen intent is what makes it ring over other apps');
    });
  });

  // -------------------------------------------------------------------------
  group('ReminderService', () {
    late _FakeScheduler scheduler;
    late InMemoryReminderMirrorStore store;
    late ReminderService service;

    setUp(() {
      scheduler = _FakeScheduler();
      store = InMemoryReminderMirrorStore();
      service = ReminderService(scheduler: scheduler, store: store);
    });

    test('arms an approved item and remembers it', () async {
      await service.sync(items: [item(id: 'a')], uid: 'me');
      expect(scheduler.scheduled.map((s) => s.$1.itemId), ['a']);
      expect((await store.load()).map((m) => m.itemId), ['a']);
    });

    test('dismiss cancels the id the MIRROR recorded, not the bare hash',
        () async {
      // A collision can move a reminder off `reminderNotificationId(itemId)`, and
      // the mirror is the authority. Seed a moved id and prove dismiss honours it.
      final moved = reminderNotificationId('a') + 7;
      await store.save([
        ScheduledReminder(
          itemId: 'a',
          notificationId: moved,
          fireAtUtc: DateTime.utc(2030),
          fingerprint: 'fp',
        ),
      ]);
      await service.dismiss('a');
      expect(scheduler.cancelled, [moved]);
      expect(scheduler.cancelled, isNot(contains(reminderNotificationId('a'))));
    });

    test('dismiss falls back to the hash when the mirror was wiped', () async {
      // The mirror can be empty after a wipe, but a fired alarm must still be
      // silenceable — the id is recomputable from the item id alone.
      await service.dismiss('gone');
      expect(scheduler.cancelled, [reminderNotificationId('gone')]);
    });

    test('a second sync with the same items does nothing at all', () async {
      await service.sync(items: [item(id: 'a')], uid: 'me');
      scheduler.reset();
      await service.sync(items: [item(id: 'a')], uid: 'me');
      expect(scheduler.scheduled, isEmpty);
      expect(scheduler.cancelled, isEmpty);
    });

    test('recording an outcome cancels the reminder, with no transition hook',
        () async {
      await service.sync(items: [item(id: 'a')], uid: 'me');
      final id = (await store.load()).single.notificationId;
      scheduler.reset();

      await service.sync(
        items: [
          item(id: 'a', outcome: const ScheduleOutcome(result: OutcomeResult.done))
        ],
        uid: 'me',
      );
      expect(scheduler.cancelled, [id]);
      expect(await store.load(), isEmpty);
    });

    test('a REFUSED schedule is kept out of the mirror and retried next pass',
        () async {
      // The exact-alarm-denied path. Recording it as armed would make every
      // later reconcile believe it exists — a reminder lost permanently and
      // silently, which is this layer's worst failure.
      scheduler.refuse.add('a');
      await service.sync(items: [item(id: 'a')], uid: 'me');
      expect(scheduler.scheduled, hasLength(1));
      expect(await store.load(), isEmpty);

      // User grants the permission and returns to the app.
      scheduler.refuse.clear();
      scheduler.reset();
      await service.sync(items: [item(id: 'a')], uid: 'me', reason: 'resume');
      expect(scheduler.scheduled.map((s) => s.$1.itemId), ['a']);
      expect(await store.load(), hasLength(1));
    });

    test('a refused item keeps the id it would have had once it succeeds',
        () async {
      scheduler.refuse.add('a');
      await service.sync(items: [item(id: 'a')], uid: 'me');
      final attempted = scheduler.scheduled.single.$2;
      scheduler.refuse.clear();
      scheduler.reset();
      await service.sync(items: [item(id: 'a')], uid: 'me');
      expect(scheduler.scheduled.single.$2, attempted);
    });

    test('signing out drops every reminder from the device', () async {
      await service.sync(items: [item(id: 'a')], uid: 'me');
      scheduler.reset();
      await service.clearAll();
      expect(scheduler.cancelAllCount, 1);
      expect(await store.load(), isEmpty);
    });

    test('switching accounts cancels the previous user\'s reminders', () async {
      // One person's reminders must never fire into another person's session,
      // and their ids must not be inherited.
      await service.sync(items: [item(id: 'a')], uid: 'me');
      scheduler.reset();

      await service.sync(items: [item(id: 'b', targetUid: 'you')], uid: 'you');
      expect(scheduler.cancelAllCount, 1);
      expect(scheduler.scheduled.map((s) => s.$1.itemId), ['b']);
      expect((await store.load()).map((m) => m.itemId), ['b']);
    });

    test('overlapping syncs are serialized, not interleaved', () async {
      // Resume racing an item emission: both read the mirror, both compute a
      // plan against a state the other is about to change, and the loser's
      // writes vanish. The queue is what stops that.
      final a = service.sync(items: [item(id: 'a')], uid: 'me');
      final b = service.sync(items: [item(id: 'a'), item(id: 'b')], uid: 'me');
      final c = service.sync(items: [item(id: 'b')], uid: 'me');
      await Future.wait([a, b, c]);

      expect((await store.load()).map((m) => m.itemId), ['b']);
      // 'a' armed then cancelled, 'b' armed once and left alone.
      expect(scheduler.scheduled.map((s) => s.$1.itemId), ['a', 'b']);
      expect(scheduler.cancelled, hasLength(1));
    });

    test('a scheduler that throws does not poison later passes', () async {
      // A broken pass must not wedge the queue — that is how one transient
      // failure becomes permanently dead reminders.
      scheduler.throwOnSchedule = true;
      await service.sync(items: [item(id: 'a')], uid: 'me');

      scheduler.throwOnSchedule = false;
      scheduler.reset();
      await service.sync(items: [item(id: 'a')], uid: 'me');
      expect(scheduler.scheduled.map((s) => s.$1.itemId), ['a']);
    });
  });
}

class _FakeScheduler implements ReminderScheduler {
  final scheduled = <(ReminderRequest, int)>[];
  final cancelled = <int>[];
  final refuse = <String>{};
  int cancelAllCount = 0;
  bool throwOnSchedule = false;

  void reset() {
    scheduled.clear();
    cancelled.clear();
    cancelAllCount = 0;
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> schedule(ReminderRequest request, int notificationId) async {
    scheduled.add((request, notificationId));
    if (throwOnSchedule) throw StateError('platform exploded');
    return !refuse.contains(request.itemId);
  }

  @override
  Future<void> cancel(int notificationId) async => cancelled.add(notificationId);

  @override
  Future<void> cancelAll() async => cancelAllCount++;
}
