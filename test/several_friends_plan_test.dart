import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/data/profile_repository.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/notifications/application/group_plan_reporter.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/group_plan_sheet.dart';
import 'package:time_app/features/voice_notes/application/group_voice_attacher.dart';
import 'package:time_app/features/voice_notes/application/voice_note_providers.dart';
import 'package:time_app/features/voice_notes/data/voice_note_client.dart';
import 'package:time_app/features/voice_notes/domain/voice_library_note.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// R4 (2026-10-02): one plan for several friends, no group. The group sheet
/// and fan-out, with an empty groupId (friendship plans), a direct minute
/// check per friend, and no group busy report.

const _meta = VoiceNoteMeta(
  durationMs: 8000,
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  sizeBytes: 9000,
);

class _Repo implements ScheduleRepository {
  _Repo({this.held = const {}, this.minuteReadFails = false});

  /// Friends whose minute already holds a live plan.
  final Set<String> held;
  final bool minuteReadFails;
  final minuteChecks = <String>[];
  final groupIds = <String>[];
  final calls = <List<String>>[];
  final knownBusy = <Set<String>>[];
  final voiceAttached = <VoiceNoteMeta>[];

  @override
  Future<bool> minuteHeldByLivePlan(String targetUid, DateTime instantUtc) {
    minuteChecks.add(targetUid);
    if (minuteReadFails) return Future.error(StateError('offline'));
    return Future.value(held.contains(targetUid));
  }

  @override
  Future<
    ({
      List<({String uid, String itemId, bool isSelf})> sent,
      int skippedPast,
      int skippedOther,
      List<({String uid, DateTime instantUtc})> failed,
    })
  >
  planForGroup({
    required String groupId,
    required String createdByUid,
    required List<({String uid, String timezone, bool isSelf})> targets,
    required String title,
    String? note,
    required DateTime wall,
    Future<VoiceNoteMeta> Function({
      required String targetUid,
      required String itemId,
    })?
    attachVoice,
    Set<String> knownBusy = const {},
  }) async {
    groupIds.add(groupId);
    calls.add([for (final t in targets) t.uid]);
    this.knownBusy.add(knownBusy);
    if (attachVoice != null) {
      for (final t in targets) {
        if (knownBusy.contains(t.uid)) continue;
        voiceAttached.add(
          await attachVoice(targetUid: t.uid, itemId: 'i-${t.uid}'),
        );
      }
    }
    return (
      sent: [
        for (final t in targets)
          if (!knownBusy.contains(t.uid))
            (uid: t.uid, itemId: 'i-${t.uid}', isSelf: t.isSelf),
      ],
      skippedPast: 0,
      skippedOther: targets.where((t) => knownBusy.contains(t.uid)).length,
      failed: [
        for (final t in targets)
          if (knownBusy.contains(t.uid))
            (uid: t.uid, instantUtc: DateTime.utc(2030, 1, 1, 18)),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Profiles implements ProfileRepository {
  @override
  Stream<UserProfile?> watchProfile(String uid) => Stream.value(
    UserProfile(uid: uid, name: 'Name $uid', homeTimezone: 'UTC'),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifier implements NotificationEventNotifier {
  final created = <String>[];

  @override
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async => created.add(targetUid);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A group-only Worker call: several friends must never reach it.
class _Reporter implements GroupPlanReporter {
  var calls = 0;

  @override
  Future<Set<String>?> reportBusy({
    required String groupId,
    required String title,
    required int setCount,
    required List<({String uid, DateTime instantUtc})> failed,
  }) async {
    calls++;
    return null;
  }

  @override
  Future<Set<String>?> availability({
    required String groupId,
    required List<({String uid, DateTime instantUtc})> members,
  }) async {
    calls++;
    return const {};
  }
}

class _VoiceClient implements VoiceNoteClient {
  final attaches = <String>[];
  final uploads = <String>[];
  final copies = <String>[];

  @override
  Future<VoiceNoteMeta> attachFromLibrary({
    required String noteId,
    required String targetUid,
    required String itemId,
    String? groupId,
  }) async {
    attaches.add('$noteId:$targetUid:$groupId');
    return _meta;
  }

  @override
  Future<VoiceNoteMeta> upload({
    required Uint8List bytes,
    required String targetUid,
    required String itemId,
    String? groupId,
  }) async {
    uploads.add('$targetUid:$groupId');
    return _meta;
  }

  @override
  Future<VoiceNoteMeta> copyToMember({
    required String fromItemId,
    required String targetUid,
    required String itemId,
    required String groupId,
  }) async {
    copies.add('$fromItemId>$targetUid:$groupId');
    return _meta;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _friends = ['FRIEND_A', 'FRIEND_B', 'FRIEND_C'];

Future<(_Repo, _Notifier, _Reporter)> _open(
  WidgetTester tester, {
  List<String> friendUids = _friends,
  _Repo? repo,
  _VoiceClient? voiceClient,
  List<VoiceLibraryNote> library = const [],
}) async {
  tester.view.physicalSize = const Size(360 * 3, 900 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final r = repo ?? _Repo();
  final notifier = _Notifier();
  final reporter = _Reporter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUidProvider.overrideWithValue('PLANNER'),
        scheduleRepositoryProvider.overrideWithValue(r),
        profileRepositoryProvider.overrideWithValue(_Profiles()),
        profileByUidProvider.overrideWith(
          (ref, uid) => Stream.value(
            UserProfile(uid: uid, name: 'Name $uid', homeTimezone: 'UTC'),
          ),
        ),
        groupPlanReporterProvider.overrideWithValue(reporter),
        notificationEventNotifierProvider.overrideWithValue(notifier),
        voiceNoteClientProvider.overrideWithValue(
          voiceClient ?? _VoiceClient(),
        ),
        voiceLibraryProvider.overrideWith((ref) => Stream.value(library)),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showFriendsPlanSheet(context, ref, friendUids: friendUids),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return (r, notifier, reporter);
}

Future<void> _pickDateAndTime(WidgetTester tester) async {
  await tester.tap(find.text('Pick date'));
  await tester.pumpAndSettle();
  if (find.text('Continue').evaluate().isNotEmpty) {
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Pick time'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('several friends sheet', () {
    testWidgets('says friends, not a group, and never includes you', (
      tester,
    ) async {
      await _open(tester);
      expect(find.text('Plan for 3 friends'), findsOneWidget);
      expect(find.textContaining('Rings for 3 friends'), findsOneWidget);
      expect(find.text('Send to 3 friends'), findsOneWidget);
      expect(find.textContaining('group'), findsNothing);
      expect(find.textContaining('member'), findsNothing);
      expect(find.textContaining('you included'), findsNothing);
    });

    testWidgets('a default alarm: one friendship plan per friend, each '
        'pushed, with no group and no group Worker call', (tester) async {
      final (repo, notifier, reporter) = await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('group-task-name')),
        'Walk',
      );
      await _pickDateAndTime(tester);
      await _send(tester, 'Send to 3 friends');

      expect(repo.groupIds, ['']);
      expect(repo.calls.single, _friends);
      expect(notifier.created, _friends);
      expect(reporter.calls, 0);
      expect(find.text('Alarm set for 3 friends.'), findsOneWidget);
    });

    testWidgets('a busy friend is found before Send, skipped and named', (
      tester,
    ) async {
      final repo = _Repo(held: {'FRIEND_B'});
      final (_, notifier, reporter) = await _open(tester, repo: repo);
      await tester.enterText(
        find.byKey(const ValueKey('group-task-name')),
        'Walk',
      );
      await _pickDateAndTime(tester);

      expect(repo.minuteChecks.toSet(), _friends.toSet());
      expect(find.byKey(const ValueKey('busy-then')), findsOneWidget);
      expect(find.textContaining('Name FRIEND_B'), findsWidgets);

      await _send(tester, 'Send to 3 friends');
      expect(repo.knownBusy.single, {'FRIEND_B'});
      expect(notifier.created, ['FRIEND_A', 'FRIEND_C']);
      // Like a single-friend plan, the busy friend is not pushed.
      expect(reporter.calls, 0);
      expect(
        find.text('Alarm set for 2 friends. Busy at that time: Name FRIEND_B.'),
        findsOneWidget,
      );
    });

    testWidgets('a failed minute check says so and still lets you send', (
      tester,
    ) async {
      final repo = _Repo(minuteReadFails: true);
      await _open(tester, repo: repo);
      await tester.enterText(
        find.byKey(const ValueKey('group-task-name')),
        'Walk',
      );
      await _pickDateAndTime(tester);
      expect(find.textContaining("Couldn't check who is busy"), findsOneWidget);
      await _send(tester, 'Send to 3 friends');
      expect(repo.calls.single, _friends);
    });

    testWidgets('a voice note goes to every friend, without a group', (
      tester,
    ) async {
      final client = _VoiceClient();
      final note = VoiceLibraryNote(
        id: 'note-1',
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        durationMs: 8000,
        sizeBytes: 9000,
        createdAt: DateTime.utc(2026, 9, 1),
      );
      final (repo, notifier, _) = await _open(
        tester,
        voiceClient: client,
        library: [note],
      );
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('group-choose-from-library')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-library-pick-note-1')));
      await tester.pumpAndSettle();
      await _pickDateAndTime(tester);
      await _send(tester, 'Send to 3 friends');

      expect(repo.groupIds, ['']);
      expect(client.attaches, [
        for (final f in _friends) 'note-1:$f:',
      ], reason: 'empty group: the Worker checks friendship');
      expect(repo.voiceAttached, hasLength(3));
      expect(notifier.created, _friends);
    });
  });

  group('friend picker', () {
    Future<List<String>?> pick(
      WidgetTester tester,
      Future<void> Function() choose,
    ) async {
      List<String>? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            profileByUidProvider.overrideWith(
              (ref, uid) => Stream.value(
                UserProfile(uid: uid, name: 'Name $uid', homeTimezone: 'UTC'),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await pickSeveralFriends(
                  context,
                  friendUids: _friends,
                ),
                child: const Text('Pick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      await choose();
      return result;
    }

    testWidgets('needs at least two friends, and keeps list order', (
      tester,
    ) async {
      final result = await pick(tester, () async {
        expect(find.text('Name FRIEND_A'), findsOneWidget);
        expect(find.text('FRIEND_A'), findsNothing, reason: 'never a uid');
        final next = find.byKey(const ValueKey('several-friends-next'));
        await tester.tap(find.byKey(const ValueKey('several-friend-FRIEND_C')));
        await tester.pump();
        expect(tester.widget<FilledButton>(next).onPressed, isNull);
        expect(find.text('Pick at least 2'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('several-friend-FRIEND_A')));
        await tester.pump();
        expect(find.text('Plan for 2'), findsOneWidget);
        await tester.tap(next);
        await tester.pumpAndSettle();
      });
      expect(result, ['FRIEND_A', 'FRIEND_C']);
    });

    testWidgets('Cancel returns nothing', (tester) async {
      final result = await pick(tester, () async {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      });
      expect(result, isNull);
    });
  });

  group('voice attacher with no group', () {
    test('uploads once, then copies to each further friend', () async {
      final client = _VoiceClient();
      final attach = GroupVoiceAttacher(
        client: client,
        groupId: '',
        recording: Uint8List.fromList([1, 2, 3]),
      );
      for (final f in _friends) {
        await attach(targetUid: f, itemId: 'i-$f');
      }
      expect(client.uploads, ['FRIEND_A:']);
      expect(client.copies, ['i-FRIEND_A>FRIEND_B:', 'i-FRIEND_A>FRIEND_C:']);
    });
  });

  test('groupPlanSentMessage counts friends for several friends', () {
    expect(
      groupPlanSentMessage(
        setCount: 1,
        skippedPast: 0,
        skippedOther: 0,
        busyNames: const [],
        notSetNames: const [],
        friends: true,
      ),
      'Alarm set for 1 friend.',
    );
    expect(
      groupPlanSentMessage(
        setCount: 2,
        skippedPast: 0,
        skippedOther: 0,
        busyNames: const [],
        notSetNames: const [],
      ),
      'Alarm set for 2 members.',
      reason: 'groups unchanged',
    );
  });
}
