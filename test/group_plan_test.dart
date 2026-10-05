import 'dart:async';
import 'dart:io';

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
import 'package:time_app/features/voice_notes/application/voice_note_providers.dart';
import 'package:time_app/features/voice_notes/data/voice_note_client.dart';
import 'package:time_app/features/voice_notes/domain/voice_library_note.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// Group alarms after F2 (2026-09-26): no approval and no Emergency switch —
/// one alarm rings for every member who gave the planner either permission.

const _self = (uid: 'PLANNER', isSelf: true);
const _normalA = (uid: 'MEMBER_A', isSelf: false);
const _normalB = (uid: 'MEMBER_B', isSelf: false);

class _Repo implements ScheduleRepository {
  var _ids = 0;

  @override
  String newItemId(String targetUid) => 'prepared-${++_ids}';

  _Repo({this.busy = const {}});

  /// Members whose minute is already taken (item 4): no plan is set for them.
  final Set<String> busy;
  final calls = <List<String>>[];

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
    String Function(String targetUid)? itemIdFor,
    Set<String> knownBusy = const {},
  }) async {
    calls.add([for (final t in targets) t.uid]);
    titles.add(title);
    lastKnownBusy = knownBusy;
    final unavailable = {...busy, ...knownBusy};
    if (attachVoice != null) {
      for (final t in targets) {
        if (t.isSelf || unavailable.contains(t.uid)) continue;
        voiceAttached.add(
          await attachVoice(targetUid: t.uid, itemId: 'i-${t.uid}'),
        );
      }
    }
    return (
      sent: [
        for (final t in targets)
          if (!unavailable.contains(t.uid))
            (uid: t.uid, itemId: 'i-${t.uid}', isSelf: t.isSelf),
      ],
      skippedPast: 0,
      skippedOther: targets.where((t) => unavailable.contains(t.uid)).length,
      failed: [
        for (final t in targets)
          if (unavailable.contains(t.uid))
            (uid: t.uid, instantUtc: DateTime.utc(2030, 1, 1, 18)),
      ],
    );
  }

  final titles = <String>[];
  Set<String> lastKnownBusy = const {};
  final voiceAttached = <VoiceNoteMeta>[];

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

/// The Worker's verdict (item 4): which of the reported members really are
/// busy. Null = the Worker could not be reached.
class _Reporter implements GroupPlanReporter {
  _Reporter(this.verdict);

  final Set<String>? verdict;

  /// The Worker never answers: Send must not wait on it (2026-09-28).
  bool hang = false;
  final reports = <({int setCount, List<String> uids})>[];

  @override
  Future<Set<String>?> reportBusy({
    required String groupId,
    required String title,
    required int setCount,
    required List<({String uid, DateTime instantUtc})> failed,
  }) async {
    reports.add((setCount: setCount, uids: [for (final f in failed) f.uid]));
    if (hang) return Completer<Set<String>?>().future;
    return verdict;
  }

  /// Before-Send preview: the same verdict, restricted to who was asked.
  Set<String>? preview;
  final previews = <List<String>>[];

  @override
  Future<Set<String>?> availability({
    required String groupId,
    required List<({String uid, DateTime instantUtc})> members,
  }) async {
    previews.add([for (final m in members) m.uid]);
    return preview;
  }
}

/// Records every voice call the sheet makes.
class _VoiceClient implements VoiceNoteClient {
  final attaches = <String>[];
  final copies = <(String, String)>[];
  final uploads = <String>[];

  static const _meta = VoiceNoteMeta(
    durationMs: 8000,
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    sizeBytes: 9000,
  );

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
  Future<VoiceNoteMeta> copyToMember({
    required String fromItemId,
    required String targetUid,
    required String itemId,
    required String groupId,
  }) async {
    copies.add((fromItemId, targetUid));
    return _meta;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(_Repo, _Notifier)> _open(
  WidgetTester tester, {
  List<({String uid, bool isSelf})> candidates = const [
    _self,
    _normalA,
    _normalB,
  ],
  ThemeData? theme,
  double width = 360,
  Map<String, String> zones = const {},
  Set<String> busy = const {},
  _Reporter? reporter,
  _VoiceClient? voiceClient,
  List<VoiceLibraryNote> library = const [],
  // 2026-10-04: the alarm kind is chosen first; most tests start from a
  // default alarm, as the sheet did before.
  bool chooseDefault = true,
}) async {
  tester.view.physicalSize = Size(width * 3, 900 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final repo = _Repo(busy: busy);
  final notifier = _Notifier();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUidProvider.overrideWithValue('PLANNER'),
        scheduleRepositoryProvider.overrideWithValue(repo),
        profileRepositoryProvider.overrideWithValue(_Profiles()),
        profileByUidProvider.overrideWith(
          (ref, uid) => Stream.value(
            UserProfile(
              uid: uid,
              name: 'Name $uid',
              homeTimezone: zones[uid] ?? 'UTC',
            ),
          ),
        ),
        groupPlanReporterProvider.overrideWithValue(reporter ?? _Reporter({})),
        notificationEventNotifierProvider.overrideWithValue(notifier),
        voiceNoteClientProvider.overrideWithValue(
          voiceClient ?? _VoiceClient(),
        ),
        voiceLibraryProvider.overrideWith((ref) => Stream.value(library)),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.light,
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showGroupPlanSheet(
                context,
                ref,
                groupId: 'group',
                groupName: 'Family',
                candidates: candidates,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  if (chooseDefault) {
    await tester.tap(find.text('Default Alarm'));
    await tester.pumpAndSettle();
  }
  return (repo, notifier);
}

/// The first pick opens the member-times pop-up (item 4); close it.
Future<void> _continuePastTimes(WidgetTester tester) async {
  if (find.text('Continue').evaluate().isNotEmpty) {
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }
}

Future<void> _fillAndSend(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('group-task-name')),
    'Evacuate',
  );
  await tester.tap(find.text('Pick date'));
  await tester.pumpAndSettle();
  await _continuePastTimes(tester);
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Pick time'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Send to the group'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('sheet', () {
    testWidgets('there is no Emergency switch and no approval wording', (
      tester,
    ) async {
      await _open(tester);
      expect(find.byKey(const ValueKey('group-plan-emergency')), findsNothing);
      expect(find.textContaining('mergency'), findsNothing);
      expect(find.textContaining('approv'), findsNothing);
      expect(find.textContaining('Rings for 3 members'), findsOneWidget);
      expect(find.text('Send to the group'), findsOneWidget);
    });

    testWidgets('a send reaches every candidate and notifies the others', (
      tester,
    ) async {
      final (repo, notifier) = await _open(tester);
      await _fillAndSend(tester);
      expect(repo.calls.single.toSet(), {'PLANNER', 'MEMBER_A', 'MEMBER_B'});
      expect(notifier.created.toSet(), {'MEMBER_A', 'MEMBER_B'});
      expect(find.textContaining('Alarm set for 3 members'), findsOneWidget);
    });

    testWidgets('the first pick shows everyone\'s time now, one line each', (
      tester,
    ) async {
      await _open(
        tester,
        zones: const {
          'MEMBER_A': 'Asia/Kolkata',
          'MEMBER_B': 'America/Vancouver',
        },
      );
      await tester.tap(find.text('Pick date'));
      await tester.pumpAndSettle();
      expect(find.text("Everyone's time now"), findsOneWidget);
      for (final uid in ['PLANNER', 'MEMBER_A', 'MEMBER_B']) {
        expect(find.byKey(ValueKey('member-time-$uid')), findsOneWidget);
      }
      // Grouped by timezone (2026-09-27): one section per zone.
      expect(find.byKey(const ValueKey('zone-UTC')), findsOneWidget);
      expect(find.byKey(const ValueKey('zone-Asia/Kolkata')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('zone-America/Vancouver')),
        findsOneWidget,
      );
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Name MEMBER_A'), findsOneWidget);
      expect(find.textContaining('Kolkata'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      // …then the date picker itself.
      expect(find.text('OK'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // It does not open by itself again; the link reopens it.
      await tester.tap(find.text('Pick time'));
      await tester.pumpAndSettle();
      expect(find.text("Everyone's time now"), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('everyones-time')));
      await tester.pumpAndSettle();
      expect(find.text("Everyone's time now"), findsOneWidget);
    });

    testWidgets('busy members are skipped, reported, and named at once', (
      tester,
    ) async {
      final reporter = _Reporter({'MEMBER_B'})..preview = {'MEMBER_B'};
      final (repo, notifier) = await _open(
        tester,
        busy: {'MEMBER_B'},
        reporter: reporter,
      );
      await _fillAndSend(tester);
      expect(notifier.created.toSet(), {'MEMBER_A'});
      expect(reporter.reports.single.uids, ['MEMBER_B']);
      expect(reporter.reports.single.setCount, 2);
      expect(
        find.text('Alarm set for 2 members. Busy at that time: Name MEMBER_B.'),
        findsOneWidget,
      );
    });

    testWidgets('a refused member the preview did not flag is "not set"', (
      tester,
    ) async {
      await _open(tester, busy: {'MEMBER_B'}, reporter: _Reporter({}));
      await _fillAndSend(tester);
      expect(find.textContaining('Busy at that time'), findsNothing);
      expect(
        find.text("Alarm set for 2 members. Couldn't set for: Name MEMBER_B."),
        findsOneWidget,
      );
    });

    testWidgets('Send never waits on the Worker (no delayed answer)', (
      tester,
    ) async {
      final reporter = _Reporter({'MEMBER_B'})
        ..preview = {'MEMBER_B'}
        ..hang = true;
      await _open(tester, busy: {'MEMBER_B'}, reporter: reporter);
      await _fillAndSend(tester);
      expect(reporter.reports, hasLength(1));
      expect(
        find.text('Alarm set for 2 members. Busy at that time: Name MEMBER_B.'),
        findsOneWidget,
      );
      expect(find.text('Send to the group'), findsNothing);
    });

    testWidgets('no report is made when everyone was set', (tester) async {
      final reporter = _Reporter({});
      await _open(tester, reporter: reporter);
      await _fillAndSend(tester);
      expect(reporter.reports, isEmpty);
    });

    for (final theme in [AppTheme.light, AppTheme.dark]) {
      testWidgets('the sheet fits a 320 px phone (${theme.brightness})', (
        tester,
      ) async {
        await _open(tester, theme: theme, width: 320);
        expect(tester.takeException(), isNull);
      });
    }
  });

  test(
    'the group screen offers EVERY member — no permission step (item 3)',
    () {
      final source = File(
        'lib/features/groups/presentation/group_detail_screen.dart',
      ).readAsStringSync();
      expect(
        source,
        contains('if (m.uid != myUid) (uid: m.uid, isSelf: false)'),
      );
      expect(source, isNot(contains('iPlanFor')));
      expect(source, isNot(contains('setPlannerGrant')));
      expect(source, isNot(contains('revokeMyPlannerGrant')));
    },
  );

  group('group voice notes + who gets it (2026-09-27)', () {
    final note = VoiceLibraryNote(
      id: 'note-1',
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      durationMs: 8000,
      sizeBytes: 9000,
      createdAt: DateTime.utc(2026, 9, 1),
    );

    Future<void> pickDateAndTime(WidgetTester tester) async {
      await tester.tap(find.text('Pick date'));
      await tester.pumpAndSettle();
      await _continuePastTimes(tester);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }

    testWidgets('switching back to Voice Note hides the date and time until '
        'a note is recorded (device report 2026-10-05)', (tester) async {
      await _open(tester, chooseDefault: false);
      final date = find.byKey(const ValueKey('group-pick-date'));
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      expect(date, findsNothing);
      await tester.tap(find.text('Default Alarm'));
      await tester.pumpAndSettle();
      expect(date, findsOneWidget);
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      expect(date, findsNothing);
    });

    testWidgets('the Plan screen layout: glowing pickers and both kinds', (
      tester,
    ) async {
      await _open(tester);
      expect(find.byKey(const ValueKey('group-pick-date')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-pick-time')), findsOneWidget);
      expect(find.text('Voice Note'), findsOneWidget);
      expect(find.text('Default Alarm'), findsOneWidget);
      // A speaker and an alarm clock beside the two kinds (2026-09-27).
      expect(find.text('🔊'), findsOneWidget);
      expect(find.text('⏰'), findsOneWidget);
      expect(find.text('Name of the Task'), findsOneWidget);
      expect(find.byKey(const ValueKey('group-note')), findsOneWidget);
    });

    testWidgets('Default Alarm needs a task name, said in red on Send', (
      tester,
    ) async {
      final (repo, _) = await _open(tester);
      await pickDateAndTime(tester);
      await tester.tap(find.text('Send to the group'));
      await tester.pumpAndSettle();
      expect(
        find.text('Please write task name. It is mandatory.'),
        findsOneWidget,
      );
      expect(repo.calls, isEmpty);
    });

    testWidgets('Voice Note with nothing recorded offers no time and no Send '
        '(2026-10-05)', (tester) async {
      final (repo, _) = await _open(tester);
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-pick-date')), findsNothing);
      expect(find.text('Send to the group'), findsNothing);
      expect(repo.calls, isEmpty);
    });

    testWidgets('a voice plan goes to the others only, each with the note', (
      tester,
    ) async {
      final client = _VoiceClient();
      final (repo, notifier) = await _open(
        tester,
        voiceClient: client,
        library: [note],
      );
      await tester.tap(find.text('Voice Note'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not to you'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('group-choose-from-library')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-library-pick-note-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-choice')), findsOneWidget);
      await pickDateAndTime(tester);
      await tester.ensureVisible(find.text('Send to the group'));
      await tester.tap(find.text('Send to the group'));
      await tester.pumpAndSettle();

      expect(repo.calls.single, ['MEMBER_A', 'MEMBER_B']); // not PLANNER
      expect(repo.titles.single, 'Voice alarm');
      expect(client.attaches, [
        'note-1:MEMBER_A:group',
        'note-1:MEMBER_B:group',
      ]);
      expect(repo.voiceAttached, hasLength(2));
      expect(notifier.created, ['MEMBER_A', 'MEMBER_B']);
    });

    testWidgets('who gets it is shown before Send, busy members named', (
      tester,
    ) async {
      final reporter = _Reporter({'MEMBER_B'})..preview = {'MEMBER_B'};
      final (repo, _) = await _open(tester, reporter: reporter);
      await pickDateAndTime(tester);
      expect(reporter.previews.last, ['MEMBER_A', 'MEMBER_B']);
      expect(find.text('Rings for 2: You, Name MEMBER_A.'), findsOneWidget);
      expect(
        find.text("Busy then, won't get it: Name MEMBER_B."),
        findsOneWidget,
      );
      // Everyone's time tags the busy member.
      await tester.tap(find.byKey(const ValueKey('everyones-time')));
      await tester.pumpAndSettle();
      expect(find.text('Busy'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('group-task-name')),
        'Evacuate',
      );
      await tester.ensureVisible(find.text('Send to the group'));
      await tester.tap(find.text('Send to the group'));
      await tester.pumpAndSettle();
      // The known-busy member is not attempted, but still reported.
      expect(repo.lastKnownBusy, {'MEMBER_B'});
      expect(reporter.reports.single.uids, ['MEMBER_B']);
    });

    testWidgets('an unreachable Worker says so and still lets you send', (
      tester,
    ) async {
      await _open(tester, reporter: _Reporter({}));
      await pickDateAndTime(tester);
      expect(find.textContaining("Couldn't check who is busy"), findsOneWidget);
    });

    testWidgets(
      'a 40-member group stays tidy: grouped, collapsed, no overflow',
      (tester) async {
        const zones = ['Asia/Kolkata', 'Europe/London', 'America/Chicago'];
        final candidates = [
          _self,
          for (var i = 0; i < 39; i++) (uid: 'M$i', isSelf: false),
        ];
        await _open(
          tester,
          candidates: candidates,
          zones: {for (var i = 0; i < 39; i++) 'M$i': zones[i % 3]},
        );
        await tester.tap(find.byKey(const ValueKey('everyones-time')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('zone-Asia/Kolkata')), findsOneWidget);
        // 13 members in the zone → 3 shown + "+10 more".
        expect(find.text('+10 more'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('zone-more-Asia/Kolkata')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('groupPlanSentMessage', () {
    String m({
      int set = 2,
      int past = 0,
      int other = 0,
      List<String> busy = const [],
      List<String> notSet = const [],
    }) => groupPlanSentMessage(
      setCount: set,
      skippedPast: past,
      skippedOther: other,
      busyNames: busy,
      notSetNames: notSet,
    );

    test('everyone set', () {
      expect(m(), 'Alarm set for 2 members.');
      expect(m(set: 1), 'Alarm set for 1 member.');
    });
    test('busy and not-set are named separately', () {
      expect(
        m(other: 2, busy: ['A'], notSet: ['B']),
        "Alarm set for 2 members. Busy at that time: A. Couldn't set for: B.",
      );
    });
    test('unnamed skips are counted', () {
      expect(m(past: 1), 'Alarm set for 2 members · 1 skipped.');
    });
    test('nobody set', () {
      expect(
        m(set: 0, past: 2),
        'That time has already passed. Pick a later time.',
      );
      expect(m(set: 0, other: 1), 'No one could be planned for right now.');
      expect(
        m(set: 0, other: 1, busy: ['A']),
        'No alarm was set. Busy at that time: A.',
      );
    });
  });
}
