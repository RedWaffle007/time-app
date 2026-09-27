import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/data/auth_repository.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/groups/domain/planner_grant.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/plan/application/plan_intent.dart';
import 'package:time_app/features/plan_requests/application/plan_request_providers.dart';
import 'package:time_app/features/plan_requests/data/plan_request_repository.dart';
import 'package:time_app/features/plan_requests/domain/plan_request.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/application/schedule_clash.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/core/widgets/field_glow.dart';
import 'package:time_app/features/scheduling/presentation/schedule_builder_screen.dart';
import 'package:time_app/features/voice_notes/domain/voice_library_note.dart';
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

/// Records what the Plan screen fulfils in request mode (item 5b).
class _PlanRequests implements PlanRequestRepository {
  final fulfilled = <Map<String, Object?>>[];

  @override
  Future<String> fulfill({
    required PlanRequest request,
    required String plannerUid,
    required String title,
    String? note,
    required DateTime wall,
    required int durationMinutes,
    bool finishFlexibleRequest = false,
    String? itemId,
    VoiceNoteMeta? voiceNote,
  }) async {
    fulfilled.add({
      'title': title,
      'note': note,
      'wall': wall,
      'duration': durationMinutes,
      'itemId': itemId,
      'voiceNote': voiceNote,
    });
    return itemId ?? 'fulfilled-item';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  final attaches = <(String, String, String, String?)>[];
  final libraryDeletes = <String>[];
  var libraryDownloads = 0;

  @override
  Future<VoiceNoteMeta> attachFromLibrary({
    required String noteId,
    required String targetUid,
    required String itemId,
    String? groupId,
  }) async {
    attaches.add((noteId, targetUid, itemId, groupId));
    return _metaFor(_audio);
  }

  final copies = <(String, String, String, String)>[];

  @override
  Future<VoiceNoteMeta> copyToMember({
    required String fromItemId,
    required String targetUid,
    required String itemId,
    required String groupId,
  }) async {
    copies.add((fromItemId, targetUid, itemId, groupId));
    return _metaFor(_audio);
  }

  @override
  Future<void> deleteLibrary(String noteId) async => libraryDeletes.add(noteId);

  @override
  Future<Uint8List> downloadLibrary(String noteId) async {
    libraryDownloads++;
    return downloadBytes ?? _audio;
  }
}

class _Repo implements ScheduleRepository {
  final created = <Map<String, Object?>>[];

  /// Makes the next createItem fail (item 4: the rules refusing a minute
  /// someone else just took).
  Object? failWith;

  int _minted = 0;

  /// The fast Send-time check (2026-09-27): is the minute held right now?
  bool minuteTaken = false;
  var minuteChecks = 0;

  @override
  Future<bool> minuteHeldByLivePlan(
    String targetUid,
    DateTime instantUtc,
  ) async {
    minuteChecks++;
    return minuteTaken;
  }

  /// The first id matches what the older tests pin; each later one differs,
  /// so a reused upload is distinguishable from a fresh one.
  @override
  String newItemId(String targetUid) =>
      'prepared-id-${(++_minted).toString().padLeft(6, '0')}';

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
    final failure = failWith;
    if (failure != null) throw failure;
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

/// A push that has not answered yet (2026-09-27: Send must not wait on it).
class _SlowNotifier implements NotificationEventNotifier {
  final gate = Completer<NotificationDeliveryResult>();
  var calls = 0;

  @override
  Future<NotificationDeliveryResult> notifyConfirmed({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) {
    calls++;
    return gate.future;
  }

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
      expect(find.text('Too short. Record at least 1 second.'), findsOneWidget);
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
      List<VoiceLibraryNote> library = const [],
      ScheduleClashChecker? checker,
      String zone = 'Etc/UTC',
      bool seeded = true,
      DateTime? seedDate,
      PlanRequest? planRequest,
      _PlanRequests? planRequests,
      NotificationEventNotifier? notifier,
      bool routed = false,
    }) async {
      final repo = _Repo();
      final voice = client ?? _Client();
      var n = 0;
      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      Widget builderScreen() => ScheduleBuilderScreen(
        initialTargetUid: target,
        initialIsSelf: target == 'me',
        initialGroupId: target == 'me' ? null : '',
        initialDate: seeded
            ? (seedDate ?? DateTime.now().add(const Duration(days: 2)))
            : null,
        initialTime: seeded ? const TimeOfDay(hour: 10, minute: 0) : null,
      );
      // With a router, the builder is pushed over a stand-in Plan page that
      // shows which sub-tab the Plan intent asked for.
      final router = routed
          ? GoRouter(
              initialLocation: '/plan',
              routes: [
                GoRoute(
                  path: '/plan',
                  builder: (context, state) => Scaffold(
                    body: Consumer(
                      builder: (context, ref, _) => Text(
                        'Plan page: ${ref.watch(planIntentProvider)?.tab}',
                      ),
                    ),
                  ),
                  routes: [
                    GoRoute(
                      path: 'schedule-builder',
                      builder: (context, state) =>
                          Scaffold(body: builderScreen()),
                    ),
                  ],
                ),
              ],
            )
          : null;
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
            profileByUidProvider.overrideWith(
              (ref, uid) => Stream.value(
                UserProfile(uid: uid, name: 'Name $uid', homeTimezone: zone),
              ),
            ),
            scheduleClashCheckerProvider.overrideWithValue(
              checker ?? ScheduleClashChecker(fetch: (_) async => []),
            ),
            scheduleRepositoryProvider.overrideWithValue(repo),
            notificationEventNotifierProvider.overrideWithValue(
              notifier ?? _Notifier(),
            ),
            voiceNoteClientProvider.overrideWithValue(voice),
            voiceLibraryProvider.overrideWith((ref) => Stream.value(library)),
            voiceRecorderFactoryProvider.overrideWithValue(
              () => _Recorder(permission: true),
            ),
            voicePlayerProvider.overrideWithValue(_Player()),
            voiceDraftPathProvider.overrideWithValue(
              () async => '${temp.path}/draft-${n++}.m4a',
            ),
            planRequestRepositoryProvider.overrideWithValue(
              planRequests ?? _PlanRequests(),
            ),
          ],
          child: router != null
              ? MaterialApp.router(theme: AppTheme.light, routerConfig: router)
              : MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  // Request mode (item 5b) is pushed over the request screen and
                  // pops itself after Send, so give it something to pop back to.
                  home: planRequest != null
                      ? Builder(
                          builder: (context) => Scaffold(
                            body: TextButton(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ScheduleBuilderScreen(
                                    planRequest: planRequest,
                                  ),
                                ),
                              ),
                              child: const Text('Request screen'),
                            ),
                          ),
                        )
                      : Scaffold(body: builderScreen()),
                ),
        ),
      );
      await tester.pumpAndSettle();
      if (router != null) {
        router.push('/plan/schedule-builder');
        await tester.pumpAndSettle();
      }
      if (planRequest != null) {
        await tester.tap(find.text('Request screen'));
        await tester.pumpAndSettle();
      }
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
      // The form can be taller than the test screen (the G2 "It's now …
      // there" line added a row), so bring Send into view like a user would.
      // Scroll (the list is lazy) rather than assume Send is already built.
      await tester.scrollUntilVisible(
        find.text('Send'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await settleIo(tester);
      await tester.pumpAndSettle();
    }

    ScheduleItem existing(DateTime instant, {ScheduleOutcome? outcome}) =>
        ScheduleItem(
          id: 'existing',
          targetUid: 'friend-1',
          createdByUid: 'someone',
          groupId: '',
          title: 'private title',
          localWallTime: '',
          timezone: 'Etc/UTC',
          scheduledInstantUtc: instant,
          status: ScheduleItemStatus.approved,
          outcome: outcome,
        );

    DateTime seededInstant() {
      final d = DateTime.now().add(const Duration(days: 2));
      return DateTime.utc(d.year, d.month, d.day, 10);
    }

    const clashLine =
        'Name friend-1 already has a plan scheduled for this time. '
        'Please select a different time.';

    bool sendEnabled(WidgetTester tester) =>
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('plan-send')))
            .onPressed !=
        null;

    testWidgets('item 4: a plan at the SAME minute blocks Send, in red', (
      tester,
    ) async {
      await pumpBuilder(
        tester,
        checker: ScheduleClashChecker(
          fetch: (_) async => [existing(seededInstant())],
        ),
      );
      expect(find.text(clashLine), findsOneWidget);
      expect(find.textContaining('private title'), findsNothing);
      expect(sendEnabled(tester), isFalse);
    });

    testWidgets('item 4: a self-plan clash says "You"', (tester) async {
      await pumpBuilder(
        tester,
        target: 'me',
        checker: ScheduleClashChecker(
          fetch: (_) async => [existing(seededInstant())],
        ),
      );
      expect(
        find.text(
          'You already have a plan scheduled for this time. '
          'Please select a different time.',
        ),
        findsOneWidget,
      );
      expect(sendEnabled(tester), isFalse);
    });

    testWidgets('item 4: an empty schedule never blocks', (tester) async {
      await pumpBuilder(tester);
      expect(find.text(clashLine), findsNothing);
      expect(sendEnabled(tester), isTrue);
    });

    testWidgets('item 4: one minute away, or a settled plan, never blocks', (
      tester,
    ) async {
      final at = seededInstant();
      await pumpBuilder(
        tester,
        checker: ScheduleClashChecker(
          fetch: (_) async => [
            existing(at.add(const Duration(minutes: 1))),
            existing(
              at,
              outcome: const ScheduleOutcome(result: OutcomeResult.done),
            ),
          ],
        ),
      );
      expect(find.text(clashLine), findsNothing);
      expect(sendEnabled(tester), isTrue);
    });

    testWidgets('item 4: an unreadable schedule does not block (the rules '
        'decide at save)', (tester) async {
      await pumpBuilder(
        tester,
        checker: ScheduleClashChecker(
          fetch: (_) async => throw Exception('permission-denied'),
          retryDelays: const [Duration.zero],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(clashLine), findsNothing);
      expect(sendEnabled(tester), isTrue);
    });

    testWidgets('item 4: taken seconds before Send — the refusal becomes the '
        'red line, not a raw error', (tester) async {
      var reads = 0;
      final (repo, _) = await pumpBuilder(
        tester,
        checker: ScheduleClashChecker(
          // Free when first checked (Send's own re-check is now the fast
          // minute-lock read, 2026-09-27); taken by the time the rules refuse
          // the write.
          fetch: (_) async => ++reads <= 1 ? [] : [existing(seededInstant())],
          retryDelays: const [],
        ),
      );
      repo.failWith = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
      await fillAndRecord(tester, record: false);
      await send(tester);
      expect(find.text(clashLine), findsOneWidget);
      expect(find.textContaining('Failed:'), findsNothing);
      expect(repo.created, isEmpty);
    });

    // Item 5b (2026-09-27): a friend's Request Plan is fulfilled through THIS
    // screen — Default Alarm or Voice Note — locked to the requested minute.
    PlanRequest request() => PlanRequest(
      id: 'req-1',
      batchId: 'b',
      requesterUid: 'friend-1',
      plannerUid: 'me',
      mode: PlanRequestMode.onePlan,
      status: PlanRequestStatus.pending,
      timezone: 'Etc/UTC',
      windowStartUtc: DateTime.utc(2030, 10, 5, 18),
      windowEndUtc: DateTime.utc(2030, 10, 5, 18, 1),
      durationMinutes: 1,
      title: 'Take medicine',
      message: 'After dinner',
    );

    testWidgets('5b: request mode opens pre-filled and locked', (tester) async {
      await pumpBuilder(tester, planRequest: request());
      expect(find.text('Name friend-1'), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-target-change')), findsNothing);
      expect(find.byKey(const ValueKey('plan-request-locked')), findsOneWidget);
      for (final key in ['pick-date', 'pick-time']) {
        final button = tester.widget<ButtonStyleButton>(
          find.byKey(ValueKey(key)),
        );
        expect(button.onPressed, isNull, reason: key);
      }
      expect(find.textContaining('Oct 5, 2030'), findsWidgets);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('task-name')))
            .controller!
            .text,
        'Take medicine',
      );
      expect(find.text('Voice Note'), findsOneWidget);
    });

    testWidgets('5b: Default Alarm fulfils the request, never a plain plan', (
      tester,
    ) async {
      final requests = _PlanRequests();
      final (repo, _) = await pumpBuilder(
        tester,
        planRequest: request(),
        planRequests: requests,
      );
      await send(tester);
      expect(repo.created, isEmpty);
      final f = requests.fulfilled.single;
      expect(f['title'], 'Take medicine');
      expect(f['note'], 'After dinner');
      expect(f['wall'], DateTime.utc(2030, 10, 5, 18));
      expect(f['duration'], 1);
      expect(f['voiceNote'], isNull);
      // Back on the request screen.
      expect(find.text('Request screen'), findsOneWidget);
    });

    testWidgets('5b: Voice Note uploads first, then fulfils with it', (
      tester,
    ) async {
      final requests = _PlanRequests();
      final (repo, voice) = await pumpBuilder(
        tester,
        planRequest: request(),
        planRequests: requests,
      );
      await fillAndRecord(tester);
      await send(tester);
      expect(voice.uploads.single.$1, 'friend-1');
      final f = requests.fulfilled.single;
      expect(f['itemId'], 'prepared-id-000001');
      expect(f['voiceNote'], isNotNull);
      expect(f['title'], kVoiceAlarmTitle);
      expect(repo.created, isEmpty);
    });

    // Batch G2 — the pickers open in the RECIPIENT's time. Fixed clock:
    // 2026-09-27 04:30Z = Sat 26 Sep 21:30 in Vancouver = Sun 27 Sep 10:00 in
    // Kolkata.
    final g2Now = DateTime.utc(2026, 9, 27, 4, 30);

    Future<(String, String)> pickDefaults(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('pick-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pick-time')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      String label(String key) => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data ?? '')
          .join(' ');
      return (label('pick-date'), label('pick-time'));
    }

    testWidgets('G2: pickers open on the recipient\'s date and time, not the '
        'planner\'s', (tester) async {
      await withClock(Clock.fixed(g2Now), () async {
        await pumpBuilder(tester, zone: 'America/Vancouver', seeded: false);
        final (date, time) = await pickDefaults(tester);
        expect(date, contains('Sat, Sep 26, 2026'));
        expect(time, contains('9:30'));
        expect(time, contains('PM'));
      });
    });

    testWidgets('G2: planner a day ahead — the picker\'s "today" is theirs', (
      tester,
    ) async {
      await withClock(Clock.fixed(g2Now), () async {
        await pumpBuilder(tester, zone: 'Pacific/Pago_Pago', seeded: false);
        // 04:30Z = Sat 26 Sep 17:30 in Pago Pago (-11), while UTC and every
        // zone east of it is already on Sunday 27.
        final (date, time) = await pickDefaults(tester);
        expect(date, contains('Sat, Sep 26, 2026'));
        expect(time, contains('5:30'));
      });
    });

    testWidgets('G2: the "It\'s now … there" line shows their time', (
      tester,
    ) async {
      await withClock(Clock.fixed(g2Now), () async {
        await pumpBuilder(tester, zone: 'America/Vancouver', seeded: false);
        final line = tester
            .widget<Text>(find.byKey(const ValueKey('time-there')))
            .data!;
        // The time keeps the locale's own spacing (a narrow no-break space
        // before PM), so compare it with plain spaces.
        expect(
          line.replaceAll('\u202f', ' '),
          "It's now 9:30 PM, Sat, Sep 26, 2026 there.",
        );
      });
    });

    testWidgets(
      'G2: a self-plan opens on your own zone, with no "there" line',
      (tester) async {
        await withClock(Clock.fixed(g2Now), () async {
          await pumpBuilder(
            tester,
            target: 'me',
            zone: 'Asia/Kolkata',
            seeded: false,
          );
          expect(find.byKey(const ValueKey('time-there')), findsNothing);
          final (date, time) = await pickDefaults(tester);
          expect(date, contains('Sun, Sep 27, 2026'));
          expect(time, contains('10:00'));
        });
      },
    );

    testWidgets('G2: an already-chosen date and time are kept', (tester) async {
      await withClock(Clock.fixed(g2Now), () async {
        await pumpBuilder(
          tester,
          zone: 'America/Vancouver',
          seedDate: DateTime(2026, 10, 20),
        );
        final (date, time) = await pickDefaults(tester);
        expect(date, contains('Tue, Oct 20, 2026'));
        expect(time, contains('10:00'));
      });
    });

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

    // ---- 2026-09-27: faster Send ----

    // 2026-09-27: the "Use this recording" confirm step is gone (on a device
    // it left Send looking dead). Record, pick date and time, Send; the note
    // uploads once, at Send.
    testWidgets('no confirm step: record, then pick date and time, and Send '
        'is on', (tester) async {
      final (_, client) = await pumpBuilder(tester, seeded: false);
      await fillAndRecord(tester);
      await tester.pumpAndSettle();
      expect(find.text('Use this recording'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('pick-date')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await pickDefaults(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('plan-send')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(sendEnabled(tester), isTrue);
      expect(client.uploads, isEmpty, reason: 'nothing uploads before Send');
    });

    testWidgets('Send uploads the recording once, then saves the plan', (
      tester,
    ) async {
      final (repo, client) = await pumpBuilder(tester);
      await fillAndRecord(tester);
      await tester.pumpAndSettle();
      expect(client.uploads, isEmpty);

      await send(tester);
      expect(client.uploads, hasLength(1));
      expect(repo.created.single['itemId'], client.uploads.single.$2);
      expect(find.text('Voice alarm sent.'), findsOneWidget);
    });

    testWidgets('re-recording sends only the latest recording', (tester) async {
      final (repo, client) = await pumpBuilder(tester);
      await fillAndRecord(tester);
      await tester.tap(find.text('Re-record'));
      await settleIo(tester);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('Stop'));
      await settleIo(tester);
      await tester.pumpAndSettle();

      await send(tester);
      expect(client.uploads, hasLength(1), reason: 'one upload, at Send');
      expect(repo.created.single['itemId'], client.uploads.single.$2);
    });

    // 2026-09-27 (user-directed): once sent, the builder closes and My
    // Schedule opens, with the confirmation showing there.
    testWidgets('after Send the builder closes onto My Schedule', (
      tester,
    ) async {
      final (repo, _) = await pumpBuilder(tester, routed: true);
      expect(find.byType(ScheduleBuilderScreen), findsOneWidget);
      await fillAndRecord(tester, record: false);
      await send(tester);
      expect(repo.created, hasLength(1));
      expect(find.byType(ScheduleBuilderScreen), findsNothing);
      expect(find.text('Plan page: ${PlanTab.mySchedule}'), findsOneWidget);
      expect(find.text('Alarm sent.'), findsOneWidget);
    });

    testWidgets('a refused Send stays on the builder', (tester) async {
      final (repo, _) = await pumpBuilder(tester, routed: true);
      repo.minuteTaken = true;
      await fillAndRecord(tester, record: false);
      await send(tester);
      expect(repo.created, isEmpty);
      expect(find.byType(ScheduleBuilderScreen), findsOneWidget);
    });

    testWidgets('the alarm kinds carry a speaker and an alarm clock', (
      tester,
    ) async {
      await pumpBuilder(tester);
      expect(kVoiceNoteEmoji, '🔊');
      expect(kDefaultAlarmEmoji, '⏰');
      for (final (emoji, label) in [
        (kVoiceNoteEmoji, 'Voice Note'),
        (kDefaultAlarmEmoji, 'Default Alarm'),
      ]) {
        final segment = find.ancestor(
          of: find.text(label),
          matching: find.byType(InkWell),
        );
        expect(
          find.descendant(of: segment.first, matching: find.text(emoji)),
          findsOneWidget,
          reason: label,
        );
      }
    });

    testWidgets('Send checks only the minute lock, and a taken minute is the '
        'red line', (tester) async {
      var fullReads = 0;
      final (repo, _) = await pumpBuilder(
        tester,
        checker: ScheduleClashChecker(
          fetch: (_) async {
            fullReads++;
            return [];
          },
          retryDelays: const [],
        ),
      );
      await tester.pumpAndSettle();
      final readsBeforeSend = fullReads;
      repo.minuteTaken = true;
      await fillAndRecord(tester, record: false);
      await send(tester);
      expect(repo.minuteChecks, 1);
      expect(fullReads, readsBeforeSend, reason: 'no full-history read');
      expect(find.text(clashLine), findsOneWidget);
      expect(repo.created, isEmpty);
    });

    testWidgets('"sent" shows at once; the push finishes in the background', (
      tester,
    ) async {
      final slow = _SlowNotifier();
      final (repo, _) = await pumpBuilder(tester, notifier: slow);
      await fillAndRecord(tester, record: false);
      await send(tester);
      expect(repo.created, hasLength(1));
      expect(slow.calls, 1);
      expect(find.text('Alarm sent.'), findsOneWidget);
      slow.gate.complete(
        const NotificationDeliveryResult(delivered: true, reason: 'sent'),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('a definite "not reached" answer follows up afterwards', (
      tester,
    ) async {
      final slow = _SlowNotifier();
      await pumpBuilder(tester, notifier: slow);
      await fillAndRecord(tester, record: false);
      await send(tester);
      slow.gate.complete(
        const NotificationDeliveryResult(delivered: false, reason: 'no-tokens'),
      );
      await tester.pump();
      await tester.pumpAndSettle(const Duration(seconds: 5));
      expect(find.textContaining('was not notified'), findsOneWidget);
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

    VoiceLibraryNote saved() => VoiceLibraryNote(
      id: 'note0000000000000001',
      sha256: _metaFor(_audio).sha256,
      durationMs: 7000,
      sizeBytes: _audio.length,
      createdAt: DateTime.utc(2030, 1, 1, 9),
      name: 'Rise and shine',
    );

    testWidgets('no library, no "Choose from library" (32d)', (tester) async {
      await pumpBuilder(tester);
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('choose-from-library')), findsNothing);
    });

    testWidgets('a library note is attached server-side, never re-uploaded', (
      tester,
    ) async {
      final (repo, client) = await pumpBuilder(tester, library: [saved()]);
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('choose-from-library')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rise and shine'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-choice')), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-note-recorder')), findsNothing);
      expect(find.textContaining('plays 5 times'), findsOneWidget);

      await send(tester);
      expect(client.uploads, isEmpty);
      expect(client.attaches.single, (
        'note0000000000000001',
        'friend-1',
        'prepared-id-000001',
        null,
      ));
      final created = repo.created.single;
      expect(created['itemId'], 'prepared-id-000001');
      expect(created['title'], kVoiceAlarmTitle);
      expect(
        (created['voiceNote'] as VoiceNoteMeta?)?.sha256,
        _metaFor(_audio).sha256,
      );
      expect(find.text('Voice alarm sent.'), findsOneWidget);
      expect(find.byKey(const ValueKey('library-choice')), findsNothing);
    });

    // Item 9 (2026-09-27): Play and X are big enough to hit, light and dark.
    for (final dark in [false, true]) {
      testWidgets('item 9: Play and X on a library note are 56 dp targets '
          'with 32 dp icons (${dark ? 'dark' : 'light'})', (tester) async {
        await pumpBuilder(tester, library: [saved()], dark: dark);
        await tester.tap(find.text('Voice Note'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('choose-from-library')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rise and shine'));
        await tester.pumpAndSettle();
        for (final key in ['library-choice-play', 'library-choice-remove']) {
          final finder = find.byKey(ValueKey(key));
          final size = tester.getSize(finder);
          expect(size.width, greaterThanOrEqualTo(Sizes.voiceChoiceButton));
          expect(size.height, greaterThanOrEqualTo(Sizes.voiceChoiceButton));
          expect(
            tester.widget<IconButton>(finder).iconSize,
            Sizes.voiceChoiceIcon,
          );
        }
        expect(
          Sizes.voiceChoiceButton,
          greaterThanOrEqualTo(Sizes.touchTarget),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('removing the library choice goes back to recording', (
      tester,
    ) async {
      final (repo, client) = await pumpBuilder(tester, library: [saved()]);
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('choose-from-library')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rise and shine'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-choice-remove')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice-note-recorder')), findsOneWidget);
      await send(tester);
      expect(find.text(kVoiceNoteRequired), findsOneWidget);
      // Nothing is attached until Send, and a removed choice is never sent.
      expect(client.attaches, isEmpty);
      expect(repo.created, isEmpty);
    });
  });
}
