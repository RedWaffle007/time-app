import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/data/auth_repository.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/groups/domain/planner_grant.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/application/target_schedule_providers.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/core/widgets/field_glow.dart';
import 'package:time_app/features/scheduling/presentation/schedule_builder_screen.dart';
import 'package:time_app/features/social/application/social_providers.dart';
import 'package:time_app/features/voice_notes/application/voice_note_cache.dart';
import 'package:time_app/features/voice_notes/application/voice_note_providers.dart';
import 'package:time_app/features/voice_notes/data/voice_note_client.dart';
import 'package:time_app/features/voice_notes/data/voice_player.dart';
import 'package:time_app/features/voice_notes/data/voice_recorder.dart';
import 'package:time_app/features/voice_notes/presentation/voice_note_recorder.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// Item 32b (2026-09-26): record a voice note in the builder, upload it
/// before the plan is saved, and let the target hear it before approving.

final _audio = Uint8List.fromList(List.generate(4096, (i) => i % 251));
VoiceNoteMeta _metaFor(Uint8List bytes) => VoiceNoteMeta(
  durationMs: 12000,
  sha256: sha256.convert(bytes).toString(),
  sizeBytes: bytes.length,
);

class _Recorder implements VoiceRecorder {
  _Recorder({this.permission = false, this.grantOnRequest = true});
  bool permission;
  final bool grantOnRequest;
  final requests = <bool>[];
  String? path;
  var cancelled = false;

  @override
  Future<bool> hasPermission({bool request = false}) async {
    requests.add(request);
    if (request) permission = grantOnRequest;
    return permission;
  }

  @override
  Future<void> start(String p) async => path = p;

  @override
  Future<String?> stop() async {
    await File(path!).writeAsBytes(_audio);
    return path;
  }

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<void> dispose() async {}
}

class _Player implements VoicePlayer {
  final played = <String>[];
  final _done = StreamController<void>.broadcast();
  @override
  Stream<void> get completed => _done.stream;
  @override
  Future<void> play(String path) async => played.add(path);
  @override
  Future<void> stop() async {}
  void finish() => _done.add(null);
}

class _Client implements VoiceNoteClient {
  _Client({this.failUpload, this.downloadBytes});
  final VoiceNoteFailure? failUpload;
  Uint8List? downloadBytes;
  final uploads = <(String, String, String?, int)>[];
  var downloads = 0;

  @override
  Future<VoiceNoteMeta> upload({
    required Uint8List bytes,
    required String targetUid,
    required String itemId,
    String? groupId,
  }) async {
    uploads.add((targetUid, itemId, groupId, bytes.length));
    if (failUpload != null) throw failUpload!;
    return _metaFor(bytes);
  }

  @override
  Future<Uint8List> download({
    required String targetUid,
    required String itemId,
  }) async {
    downloads++;
    return downloadBytes ?? _audio;
  }
}

class _Repo implements ScheduleRepository {
  final created = <Map<String, Object?>>[];

  @override
  String newItemId(String targetUid) => 'prepared-id-000001';

  @override
  Future<String> createItem({
    required String targetUid,
    required String createdByUid,
    String? groupId,
    required String title,
    String? note,
    required DateTime wall,
    required String timezone,
    ScheduleItemStatus status = ScheduleItemStatus.pending,
    ItemTier tier = ItemTier.normal,
    int durationMinutes = 0,
    String? planRequestId,
    String? itemId,
    VoiceNoteMeta? voiceNote,
  }) async {
    created.add({
      'targetUid': targetUid,
      'itemId': itemId,
      'voiceNote': voiceNote,
      'status': status,
      'tier': tier,
      'title': title,
    });
    return itemId ?? 'auto-id';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifier implements NotificationEventNotifier {
  @override
  Future<NotificationDeliveryResult> notifyConfirmed({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async => const NotificationDeliveryResult(delivered: true, reason: 'sent');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUser implements User {
  @override
  String get uid => 'me';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth implements AuthRepository {
  @override
  User? get currentUser => _FakeUser();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Lets real file I/O (the recorder's file, the builder's read) finish and
/// its continuations run on the test clock.
Future<void> settleIo(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('voice-test'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('Worker client', () {
    test('an upload reply becomes metadata', () {
      final sha = 'a' * 64;
      final meta = parseUploadResponse(
        200,
        '{"sha256":"$sha","durationMs":12345,"sizeBytes":9000}',
      );
      expect(meta.sha256, sha);
      expect(meta.durationMs, 12345);
      expect(meta.sizeBytes, 9000);
      expect(meta.toCreateMap(), {
        'durationMs': 12345,
        'sha256': sha,
        'sizeBytes': 9000,
      });
    });

    test('every refusal becomes a plain sentence, never a code', () {
      for (final (status, code, words) in [
        (413, 'too-long', 'at most 20 seconds'),
        (400, 'too-short', 'too short'),
        (415, 'unsupported-type', "couldn't be read"),
        (403, 'no-planning-permission', "can't plan for this person"),
        (409, 'item-exists', 'fixed'),
        (500, 'voice-failed', 'Check your connection'),
      ]) {
        expect(
          () => parseUploadResponse(status, '{"error":"$code"}'),
          throwsA(
            isA<VoiceNoteFailure>().having(
              (e) => e.message,
              'message',
              contains(words),
            ),
          ),
        );
      }
      // A 200 without the fields is not trusted.
      expect(
        () => parseUploadResponse(200, '{}'),
        throwsA(isA<VoiceNoteFailure>()),
      );
    });
  });

  group('metadata', () {
    test(
      'parses from Firestore data, tolerating a receipt, rejecting junk',
      () {
        final meta = VoiceNoteMeta.fromMap({
          'durationMs': 12000,
          'sha256': 'a' * 64,
          'sizeBytes': 9000,
        });
        expect(meta?.durationMs, 12000);
        expect(meta?.deliveredAt, isNull);
        expect(VoiceNoteMeta.fromMap(null), isNull);
        expect(VoiceNoteMeta.fromMap({'sha256': 'x'}), isNull);
        expect(VoiceNoteMeta.fromMap('nope'), isNull);
      },
    );
  });

  group('verified cache', () {
    ScheduleItem item(VoiceNoteMeta? meta) => ScheduleItem(
      id: 'item-1',
      targetUid: 'TARGET',
      createdByUid: 'PLANNER',
      groupId: '',
      title: 'Wake up',
      localWallTime: '',
      timezone: 'Etc/UTC',
      scheduledInstantUtc: DateTime.utc(2030),
      status: ScheduleItemStatus.pending,
      voiceNote: meta,
    );

    test('downloads once, verifies, then reuses the local copy', () async {
      final client = _Client();
      final cache = VoiceNoteCache(client, () async => temp);
      final path = await cache.ensure(item(_metaFor(_audio)));
      expect(await File(path).readAsBytes(), _audio);
      await cache.ensure(item(_metaFor(_audio)));
      expect(client.downloads, 1);
    });

    test('a damaged local copy is replaced', () async {
      final client = _Client();
      final cache = VoiceNoteCache(client, () async => temp);
      final path = await cache.ensure(item(_metaFor(_audio)));
      await File(path).writeAsBytes([1, 2, 3]);
      await cache.ensure(item(_metaFor(_audio)));
      expect(client.downloads, 2);
      expect(await File(path).readAsBytes(), _audio);
    });

    test('bytes that do not match the plan are refused and not kept', () async {
      final client = _Client(downloadBytes: Uint8List.fromList([9, 9, 9]));
      final cache = VoiceNoteCache(client, () async => temp);
      await expectLater(
        cache.ensure(item(_metaFor(_audio))),
        throwsA(isA<VoiceNoteFailure>()),
      );
      expect(File('${temp.path}/voice-notes/item-1.m4a').existsSync(), isFalse);
      expect(voiceBytesMatch(_audio, _metaFor(_audio)), isTrue);
    });

    test('no voice note → a clear failure', () async {
      final cache = VoiceNoteCache(_Client(), () async => temp);
      expect(cache.ensure(item(null)), throwsA(isA<VoiceNoteFailure>()));
    });
  });

  group('recorder', () {
    Future<(List<RecordedVoiceNote?>, _Recorder, _Player)> pump(
      WidgetTester tester, {
      bool permission = false,
      bool grant = true,
    }) async {
      final changes = <RecordedVoiceNote?>[];
      final recorder = _Recorder(permission: permission, grantOnRequest: grant);
      final player = _Player();
      var n = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            voiceRecorderFactoryProvider.overrideWithValue(() => recorder),
            voicePlayerProvider.overrideWithValue(player),
            voiceDraftPathProvider.overrideWithValue(
              () async => '${temp.path}/draft-${n++}.m4a',
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: VoiceNoteRecorder(
                recipientName: 'Test Target',
                onChanged: changes.add,
              ),
            ),
          ),
        ),
      );
      return (changes, recorder, player);
    }

    testWidgets('the microphone is only asked for after an explanation', (
      tester,
    ) async {
      final (_, recorder, _) = await pump(tester);
      await tester.tap(find.text('Record'));
      await settleIo(tester);
      await tester.pumpAndSettle();
      expect(find.text('Use your microphone?'), findsOneWidget);
      expect(find.textContaining('microphone is only on'), findsOneWidget);
      expect(recorder.requests, [false], reason: 'no OS prompt yet');

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(recorder.requests, [false], reason: 'declining never prompts');
      expect(find.text('Record'), findsOneWidget);
    });

    testWidgets('a refused permission explains how to turn it on', (
      tester,
    ) async {
      await pump(tester, grant: false);
      await tester.tap(find.text('Record'));
      await settleIo(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Turn it on in Settings'), findsOneWidget);
      expect(find.text('Record'), findsOneWidget);
    });

    testWidgets('record, stop, preview, discard', (tester) async {
      final (changes, _, player) = await pump(tester, permission: true);
      await tester.tap(find.text('Record'));
      await settleIo(tester);
      await tester.pump();
      expect(find.textContaining('Recording…'), findsOneWidget);
      expect(find.textContaining('/ 0:20'), findsOneWidget);

      await tester.pump(const Duration(seconds: 7));
      await tester.tap(find.text('Stop'));
      await settleIo(tester);
      await tester.pump();
      expect(changes.single, isNotNull);
      expect(changes.single!.length.inSeconds, 7);
      expect(
        find.text('Voice note ready · 0:07 · plays 5 times'),
        findsOneWidget,
      );
      final path = changes.single!.path;
      expect(File(path).existsSync(), isTrue);
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Re-record'), findsOneWidget);

      await tester.tap(find.text('Play'));
      await tester.pump();
      expect(player.played, [path]);
      expect(find.text('Stop'), findsOneWidget);
      player.finish();
      await tester.pump();
      expect(find.text('Play'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await settleIo(tester);
      await tester.pump();
      expect(changes.last, isNull);
      expect(
        File(path).existsSync(),
        isFalse,
        reason: 'never sent, so deleted',
      );
      expect(find.text('Record'), findsOneWidget);
    });

    testWidgets('recording stops itself at 20 seconds', (tester) async {
      final (changes, _, _) = await pump(tester, permission: true);
      await tester.tap(find.text('Record'));
      await settleIo(tester);
      await tester.pump();
      await tester.pump(kMaxVoiceNote);
      await settleIo(tester);
      expect(changes, isNotEmpty);
      expect(find.text('Re-record'), findsOneWidget);
    });

    testWidgets('a note under a second is thrown away and explained (F5)', (
      tester,
    ) async {
      final (changes, _, _) = await pump(tester, permission: true);
      await tester.tap(find.text('Record'));
      await settleIo(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.text('Stop'));
      await settleIo(tester);
      await tester.pump();
      expect(changes.single, isNull);
      expect(
        find.text('Too short — record at least 1 second.'),
        findsOneWidget,
      );
      expect(find.text('Record'), findsOneWidget);
      expect(
        File('${temp.path}/draft-0.m4a').existsSync(),
        isFalse,
        reason: 'the short file is deleted',
      );

      // Recording again clears the warning.
      await tester.tap(find.text('Record'));
      await settleIo(tester);
      await tester.pump();
      expect(find.textContaining('Too short'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Stop'));
      await settleIo(tester);
      await tester.pump();
      expect(changes.last, isNotNull, reason: 'exactly 1 s is accepted');
      expect(find.textContaining('plays 6 times'), findsOneWidget);
    });

    test('plays scale with length; boundaries take the longer band (F5)', () {
      const cases = {
        20500: 3, 20000: 3, 15001: 3, 15000: 3, //
        14999: 4, 10000: 4, //
        9999: 5, 5000: 5, //
        4999: 6, 1000: 6,
      };
      cases.forEach((ms, plays) {
        expect(
          voicePlaysFor(Duration(milliseconds: ms)),
          plays,
          reason: '$ms ms',
        );
      });
      expect(kMinVoiceNote, const Duration(seconds: 1));
    });

    test('Dart and native agree on the bands', () {
      final native = File(
        'android/app/src/main/kotlin/com/timeapp/time_app/reminders/VoiceAlarm.kt',
      ).readAsStringSync();
      for (final line in [
        'durationMs >= 15_000 -> 3',
        'durationMs >= 10_000 -> 4',
        'durationMs >= 5_000 -> 5',
        'else -> 6',
      ]) {
        expect(native, contains(line));
      }
      final worker = File('worker/src/voice.js').readAsStringSync();
      expect(worker, contains('MIN_VOICE_MS = 1_000'));
    });

    test('lengths read as m:ss in any locale', () {
      expect(formatVoiceLength(Duration.zero), '0:00');
      expect(formatVoiceLength(const Duration(seconds: 9)), '0:09');
      expect(formatVoiceLength(kMaxVoiceNote), '0:20');
    });
  });

  group('builder', () {
    Future<(_Repo, _Client)> pumpBuilder(
      WidgetTester tester, {
      _Client? client,
      String target = 'friend-1',
      bool dark = false,
    }) async {
      final repo = _Repo();
      final voice = client ?? _Client();
      var n = 0;
      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(_Auth()),
            effectivePlanningTargetsProvider.overrideWithValue(
              const AsyncData([
                PlannerGrant(
                  plannerUid: 'me',
                  targetUid: 'friend-1',
                  groupId: '',
                  granted: true,
                ),
              ]),
            ),
            iCanEmergencyPlanForProvider.overrideWith(
              (ref, uid) => const AsyncData(false),
            ),
            profileByUidProvider.overrideWith(
              (ref, uid) => Stream.value(
                UserProfile(
                  uid: uid,
                  name: 'Name $uid',
                  homeTimezone: 'Etc/UTC',
                ),
              ),
            ),
            targetScheduleProvider.overrideWith((ref, uid) => Stream.value([])),
            scheduleRepositoryProvider.overrideWithValue(repo),
            notificationEventNotifierProvider.overrideWithValue(_Notifier()),
            voiceNoteClientProvider.overrideWithValue(voice),
            voiceRecorderFactoryProvider.overrideWithValue(
              () => _Recorder(permission: true),
            ),
            voicePlayerProvider.overrideWithValue(_Player()),
            voiceDraftPathProvider.overrideWithValue(
              () async => '${temp.path}/draft-${n++}.m4a',
            ),
          ],
          child: MaterialApp(
            theme: dark ? AppTheme.dark : AppTheme.light,
            home: Scaffold(
              body: ScheduleBuilderScreen(
                initialTargetUid: target,
                initialIsSelf: target == 'me',
                initialGroupId: target == 'me' ? null : '',
                initialDate: DateTime.now().add(const Duration(days: 2)),
                initialTime: const TimeOfDay(hour: 10, minute: 0),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (repo, voice);
    }

    Future<void> fillAndRecord(
      WidgetTester tester, {
      bool record = true,
    }) async {
      if (!record) {
        await tester.enterText(
          find.byKey(const ValueKey('task-name')),
          'Wake up',
        );
        await tester.pump();
        return;
      }
      // F4: a voice alarm is chosen, and has no name field.
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      {
        await tester.tap(find.text('Record'));
        await settleIo(tester);
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        await tester.tap(find.text('Stop'));
        await settleIo(tester);
        await tester.pump();
      }
    }

    Future<void> send(WidgetTester tester) async {
      await tester.tap(find.text('Send'));
      await settleIo(tester);
      await tester.pumpAndSettle();
    }

    testWidgets('the recorder shows for someone else, never for yourself', (
      tester,
    ) async {
      await pumpBuilder(tester);
      // Default Alarm is preselected; Voice Note reveals the recorder.
      expect(find.byKey(const ValueKey('voice-note-recorder')), findsNothing);
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice-note-recorder')), findsOneWidget);
      expect(find.byKey(const ValueKey('task-name')), findsNothing);
    });

    testWidgets('planning for yourself has no voice note', (tester) async {
      await pumpBuilder(tester, target: 'me');
      expect(find.byKey(const ValueKey('voice-note-recorder')), findsNothing);
      expect(find.byKey(const ValueKey('alarm-kind')), findsNothing);
      expect(find.text('Voice Note'), findsNothing);
      expect(find.byKey(const ValueKey('task-name')), findsOneWidget);
    });

    testWidgets('the note is uploaded first, then the plan saved with it', (
      tester,
    ) async {
      final (repo, client) = await pumpBuilder(tester);
      await fillAndRecord(tester);
      await send(tester);

      expect(client.uploads.single.$1, 'friend-1');
      expect(client.uploads.single.$2, 'prepared-id-000001');
      expect(client.uploads.single.$3, isNull, reason: 'friendship plan');
      expect(client.uploads.single.$4, _audio.length);
      final created = repo.created.single;
      expect(created['itemId'], 'prepared-id-000001');
      expect(
        (created['voiceNote'] as VoiceNoteMeta?)?.sha256,
        _metaFor(_audio).sha256,
      );
      expect(created['title'], kVoiceAlarmTitle);
      expect(find.text('Voice alarm sent.'), findsOneWidget);
      // The draft is gone and the recorder is fresh for the next plan.
      expect(find.text('Record'), findsOneWidget);
    });

    testWidgets('a refused upload saves nothing and says why', (tester) async {
      final (repo, _) = await pumpBuilder(
        tester,
        client: _Client(
          failUpload: const VoiceNoteFailure(
            'Voice notes can be at most 20 seconds.',
          ),
        ),
      );
      await fillAndRecord(tester);
      await send(tester);
      expect(repo.created, isEmpty);
      expect(
        find.text('Voice notes can be at most 20 seconds.'),
        findsOneWidget,
      );
      expect(find.text('Play'), findsOneWidget, reason: 'the draft is kept');
    });

    testWidgets('without a recording the plan saves exactly as before', (
      tester,
    ) async {
      final (repo, client) = await pumpBuilder(tester);
      await fillAndRecord(tester, record: false);
      await send(tester);
      expect(client.uploads, isEmpty);
      expect(repo.created.single['itemId'], isNull);
      expect(repo.created.single['voiceNote'], isNull);
      // F2: every alarm is saved approved — it rings with no approval step.
      expect(repo.created.single['status'], ScheduleItemStatus.approved);
      expect(repo.created.single['tier'], ItemTier.normal);
      expect(find.text('Emergency'), findsNothing);
      expect(find.text('Alarm sent.'), findsOneWidget);
    });

    testWidgets('an empty task name is refused in red, and typing clears it', (
      tester,
    ) async {
      final (repo, _) = await pumpBuilder(tester);
      await send(tester);
      expect(repo.created, isEmpty);
      expect(find.text(kTaskNameRequired), findsOneWidget);
      expect(
        tester.widget<Text>(find.text(kTaskNameRequired)).style?.color,
        AppTheme.light.colorScheme.error,
      );
      await tester.enterText(find.byKey(const ValueKey('task-name')), 'Run');
      await tester.pump();
      expect(find.text(kTaskNameRequired), findsNothing);
      await send(tester);
      expect(repo.created.single['title'], 'Run');
    });

    testWidgets('Voice Note without a recording asks for one', (tester) async {
      final (repo, client) = await pumpBuilder(tester);
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      await send(tester);
      expect(repo.created, isEmpty);
      expect(client.uploads, isEmpty);
      expect(find.text(kVoiceNoteRequired), findsOneWidget);
      expect(find.text(kTaskNameRequired), findsNothing);
    });

    testWidgets('the layout: possessive zone line, glowing inputs, Send', (
      tester,
    ) async {
      await pumpBuilder(tester);
      expect(
        find.textContaining("You're building in Name friend-1's local time"),
        findsOneWidget,
      );
      expect(find.text('Name of the Task'), findsOneWidget);
      expect(find.text('Note (optional)'), findsOneWidget);
      // Pick date, Pick time, task name and note each sit in a field glow.
      expect(find.byType(FieldGlow), findsNWidgets(4));
      expect(
        tester.getSize(find.byKey(const ValueKey('pick-date'))).height,
        greaterThanOrEqualTo(Sizes.pickerButton),
      );
      // Order: date/time → choice → name → note → Send.
      double top(Finder f) => tester.getRect(f).top;
      expect(
        top(find.byKey(const ValueKey('pick-date'))),
        lessThan(top(find.byKey(const ValueKey('alarm-kind')))),
      );
      expect(
        top(find.byKey(const ValueKey('alarm-kind'))),
        lessThan(top(find.byKey(const ValueKey('task-name')))),
      );
      expect(
        top(find.byKey(const ValueKey('task-name'))),
        lessThan(top(find.byKey(const ValueKey('note')))),
      );
      expect(
        top(find.byKey(const ValueKey('note'))),
        lessThan(top(find.byKey(const ValueKey('plan-send')))),
      );
    });

    testWidgets('the builder renders in dark mode too', (tester) async {
      await pumpBuilder(tester, dark: true);
      expect(tester.takeException(), isNull);
      expect(find.byType(FieldGlow), findsNWidgets(4));
      await send(tester);
      expect(
        tester.widget<Text>(find.text(kTaskNameRequired)).style?.color,
        AppTheme.dark.colorScheme.error,
      );
    });
  });
}
