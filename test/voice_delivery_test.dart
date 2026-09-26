import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/voice_notes/application/voice_delivery_policy.dart';
import 'package:time_app/features/voice_notes/application/voice_delivery_reconciler.dart';
import 'package:time_app/features/voice_notes/application/voice_note_cache.dart';
import 'package:time_app/features/voice_notes/application/voice_rescue.dart';
import 'package:time_app/features/voice_notes/data/voice_note_client.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';

/// Item 32c-1 (2026-09-26): the voice note reaches the target's phone before
/// the alarm, the planner can see it did, and old copies are cleaned up.

final _audio = Uint8List.fromList(List.generate(2048, (i) => (i * 7) % 256));
final _meta = VoiceNoteMeta(
  durationMs: 12000,
  sha256: sha256.convert(_audio).toString(),
  sizeBytes: _audio.length,
);
final _now = DateTime.utc(2030, 1, 1, 9);

ScheduleItem _item(
  String id, {
  ScheduleItemStatus status = ScheduleItemStatus.approved,
  VoiceNoteMeta? meta,
  bool noNote = false,
  Duration inFuture = const Duration(hours: 2),
  String target = 'ME',
  String creator = 'PLANNER',
  ScheduleOutcome? outcome,
}) => ScheduleItem(
  id: id,
  targetUid: target,
  createdByUid: creator,
  groupId: '',
  title: 'Wake up',
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: _now.add(inFuture),
  status: status,
  outcome: outcome,
  voiceNote: noNote ? null : (meta ?? _meta),
);

class _Client implements VoiceNoteClient {
  _Client({this.fail = false});
  bool fail;
  var downloads = 0;

  @override
  Future<Uint8List> download({
    required String targetUid,
    required String itemId,
  }) async {
    downloads++;
    if (fail) throw const VoiceNoteFailure('offline');
    return _audio;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('delivery rule', () {
    test(
      'fetch only approved, unanswered, future alarms of mine with a note',
      () {
        final plan = planVoiceDelivery(
          [
            _item('ok'),
            _item('pending', status: ScheduleItemStatus.pending),
            _item('past', inFuture: const Duration(minutes: -5)),
            _item(
              'done',
              outcome: const ScheduleOutcome(result: OutcomeResult.done),
            ),
            _item('no-note', noNote: true),
            _item('not-mine', target: 'SOMEONE'),
            _item('self', creator: 'ME'),
            _item('rejected', status: ScheduleItemStatus.rejected),
          ],
          'ME',
          _now,
        );
        expect(plan.fetch.map((i) => i.id), ['ok']);
      },
    );

    test('only undelivered ones need a receipt', () {
      final delivered = VoiceNoteMeta(
        durationMs: 1,
        sha256: _meta.sha256,
        sizeBytes: _meta.sizeBytes,
        deliveredAt: _now,
      );
      final plan = planVoiceDelivery(
        [_item('new'), _item('old', meta: delivered)],
        'ME',
        _now,
      );
      expect(plan.fetch.map((i) => i.id), ['new', 'old']);
      expect(plan.receipt.map((i) => i.id), ['new']);
    });

    test('copies are kept while live, for a day after the alarm', () {
      final plan = planVoiceDelivery(
        [
          _item('upcoming'),
          _item('pending', status: ScheduleItemStatus.pending),
          _item('just-rang', inFuture: const Duration(hours: -3)),
          _item('long-gone', inFuture: const Duration(days: -3)),
          _item(
            'answered',
            outcome: const ScheduleOutcome(result: OutcomeResult.done),
          ),
        ],
        'ME',
        _now,
      );
      expect(plan.keepIds, {'upcoming', 'pending', 'just-rang'});
    });
  });

  group('planner status line', () {
    test('says where the note is, and nothing once settled', () {
      expect(
        plannerVoiceNoteStatus(_item('p', status: ScheduleItemStatus.pending)),
        'Voice note attached',
      );
      expect(
        plannerVoiceNoteStatus(_item('a')),
        'Voice note not on their phone yet',
      );
      expect(
        plannerVoiceNoteStatus(
          _item(
            'd',
            meta: VoiceNoteMeta(
              durationMs: 1,
              sha256: 'x',
              sizeBytes: 1,
              deliveredAt: _now,
            ),
          ),
        ),
        'Voice note on their phone',
      );
      expect(
        plannerVoiceNoteStatus(
          _item(
            's',
            outcome: const ScheduleOutcome(result: OutcomeResult.done),
          ),
        ),
        isNull,
      );
      expect(plannerVoiceNoteStatus(_item('n', noNote: true)), isNull);
    });

    test('the planner activity card shows it', () {
      final source = File(
        'lib/features/scheduling/presentation/planner_activity_screen.dart',
      ).readAsStringSync();
      expect(source, contains('plannerVoiceNoteStatus(item)'));
    });
  });

  group('reconciler', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('voice-delivery'));
    tearDown(() => temp.deleteSync(recursive: true));

    test(
      'fetches, verifies, stamps the receipt once, and is idempotent',
      () async {
        final client = _Client();
        final receipts = <String>[];
        final r = VoiceDeliveryReconciler(
          VoiceNoteCache(client, () async => temp),
          (item) async => receipts.add(item.id),
        );
        final first = await r.reconcile(
          uid: 'ME',
          items: [_item('a')],
          now: _now,
        );
        expect(first.fetched, 1);
        expect(receipts, ['a']);
        expect(
          File('${temp.path}/voice-notes/a.m4a').readAsBytesSync(),
          _audio,
        );

        // Once the receipt is on the item, nothing more is written or fetched.
        final stamped = _item(
          'a',
          meta: VoiceNoteMeta(
            durationMs: 1,
            sha256: _meta.sha256,
            sizeBytes: _meta.sizeBytes,
            deliveredAt: _now,
          ),
        );
        final second = await r.reconcile(
          uid: 'ME',
          items: [stamped],
          now: _now,
        );
        expect(second.fetched, 0);
        expect(receipts, ['a']);
        expect(client.downloads, 1);
      },
    );

    test('offline: no receipt, and a later pass delivers', () async {
      final client = _Client(fail: true);
      final receipts = <String>[];
      final r = VoiceDeliveryReconciler(
        VoiceNoteCache(client, () async => temp),
        (item) async => receipts.add(item.id),
      );
      await r.reconcile(uid: 'ME', items: [_item('a')], now: _now);
      expect(receipts, isEmpty, reason: 'never claim delivery without a copy');
      client.fail = false;
      await r.resync();
      expect(receipts, ['a']);
    });

    test('one failure does not stop the others', () async {
      final receipts = <String>[];
      final r = VoiceDeliveryReconciler(
        VoiceNoteCache(_Client(), () async => temp),
        (item) async {
          if (item.id == 'bad') throw StateError('rules');
          receipts.add(item.id);
        },
      );
      await r.reconcile(
        uid: 'ME',
        items: [_item('bad'), _item('good')],
        now: _now,
      );
      expect(receipts, ['good']);
    });

    test('copies no longer needed are deleted; wanted ones kept', () async {
      final dir = Directory('${temp.path}/voice-notes')..createSync();
      File('${dir.path}/stale.m4a').writeAsBytesSync([1]);
      File('${dir.path}/keep.m4a').writeAsBytesSync(_audio);
      File('${dir.path}/notes.txt').writeAsStringSync('not ours');
      final r = VoiceDeliveryReconciler(
        VoiceNoteCache(_Client(), () async => temp),
        (_) async {},
      );
      final result = await r.reconcile(
        uid: 'ME',
        items: [_item('keep', status: ScheduleItemStatus.pending)],
        now: _now,
      );
      expect(result.pruned, 1);
      expect(File('${dir.path}/stale.m4a').existsSync(), isFalse);
      expect(File('${dir.path}/keep.m4a').existsSync(), isTrue);
      expect(File('${dir.path}/notes.txt').existsSync(), isTrue);
    });

    test('signed out: nothing happens', () async {
      final client = _Client();
      final r = VoiceDeliveryReconciler(
        VoiceNoteCache(client, () async => temp),
        (_) async => fail('no receipt when signed out'),
      );
      await r.reconcile(uid: null, items: [_item('a')], now: _now);
      expect(client.downloads, 0);
    });

    test('the arming path is known before the file exists', () async {
      final cache = VoiceNoteCache(_Client(), () async => temp);
      expect(await cache.pathFor('abc'), '${temp.path}/voice-notes/abc.m4a');
      expect(await cache.hasVerified(_item('abc')), isFalse);
    });
  });

  group('rescue push', () {
    test('only a well-formed fetch command is accepted', () {
      expect(
        voiceFetchRequestFromPushData({
          'command': 'fetchVoiceNote',
          'targetUid': 'ME',
          'itemId': 'a',
        }),
        (targetUid: 'ME', itemId: 'a'),
      );
      for (final data in [
        {'command': 'scheduleReminder', 'targetUid': 'ME', 'itemId': 'a'},
        {'command': 'fetchVoiceNote', 'targetUid': '', 'itemId': 'a'},
        {'command': 'fetchVoiceNote', 'targetUid': 'ME'},
        <String, dynamic>{},
      ]) {
        expect(voiceFetchRequestFromPushData(data), isNull, reason: '$data');
      }
    });

    test('the killed-app handler and the open app both act on it', () {
      final background = File(
        'lib/features/notifications/application/messaging_service.dart',
      ).readAsStringSync();
      expect(background, contains('fetchVoiceNoteInBackground(voiceFetch)'));
      final app = File('lib/app.dart').readAsStringSync();
      expect(app, contains('voiceFetchRequestFromPushData(message.data)'));
      expect(app, contains('ref.watch(voiceDeliverySyncProvider)'));
    });

    testWidgets('the planner warning opens Plan activity', (tester) async {
      final router = GoRouter(
        initialLocation: Routes.you,
        routes: [
          GoRoute(path: Routes.plan, builder: (_, _) => const Text('Plan')),
          GoRoute(path: Routes.you, builder: (_, _) => const Text('You')),
        ],
      );
      final container = ProviderContainer(
        overrides: [routerProvider.overrideWithValue(router)],
      );
      addTearDown(container.dispose);
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      container.read(notificationRouterProvider).openForPushEvent({
        'event': 'voiceUndelivered',
        'itemId': 'a',
      });
      await tester.pumpAndSettle();
      expect(find.text('Plan'), findsOneWidget);
    });
  });
}
