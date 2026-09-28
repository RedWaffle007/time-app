import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/status_style.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/outcomes/application/outcome_feedback.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/reminders/application/voice_heard_reconciler.dart';
import 'package:time_app/features/scheduling/application/item_lapse_policy.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/voice_notes/application/voice_note_cache.dart';
import 'package:time_app/features/voice_notes/application/voice_note_providers.dart';
import 'package:time_app/features/voice_notes/data/voice_player.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// Voice notes without Done/Skip (2026-09-28, DECISIONS.md "Voice notes
/// without Done/Skip"): dismissed while ringing = Heard; rang out = missed
/// popup / card with Play · Already heard = Heard (Late); 24 h unanswered =
/// Did not respond (Missed).

const _meta = VoiceNoteMeta(
  durationMs: 8000,
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  sizeBytes: 9000,
);

ScheduleItem _item({
  String id = 'v',
  String creator = 'planner',
  VoiceNoteMeta? voiceNote = _meta,
  DateTime? at,
  ScheduleAlarmTimeline? alarm,
  ScheduleOutcome? outcome,
}) => ScheduleItem(
  id: id,
  targetUid: 'me',
  createdByUid: creator,
  groupId: '',
  title: 'Voice note',
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: at ?? DateTime.utc(2030, 1, 1, 9),
  status: ScheduleItemStatus.approved,
  alarm: alarm,
  outcome: outcome,
  voiceNote: voiceNote,
);

class _Repo implements ScheduleRepository {
  final done = <String>[];

  @override
  Future<bool> markDone(
    String targetUid,
    String itemId, {
    required String plannerUid,
  }) async {
    done.add('$targetUid/$itemId/$plannerUid');
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifier implements NotificationEventNotifier {
  final events = <NotifyEvent>[];

  @override
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async => events.add(event);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cache implements VoiceNoteCache {
  @override
  Future<String> ensure(ScheduleItem item) async => '/voice/${item.id}.m4a';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements VoicePlayer {
  final played = <String>[];

  @override
  Future<void> play(String path) async => played.add(path);

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get completed => const Stream.empty();
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('only a voice note someone else sent is a voice alarm', () {
    expect(_item().isVoiceAlarm, isTrue);
    expect(_item(creator: 'me').isVoiceAlarm, isFalse);
    expect(_item(voiceNote: null).isVoiceAlarm, isFalse);
  });

  group('24-hour close', () {
    final at = DateTime.utc(2030, 1, 1, 9);
    test('a voice note lapses 24 h after its alarm, not at day end', () {
      final voice = _item(at: at);
      expect(responseDeadlineUtc(voice), at.add(const Duration(hours: 24)));
      expect(hasLapsed(voice, DateTime.utc(2030, 1, 2, 0, 30)), isFalse);
      expect(hasLapsed(voice, DateTime.utc(2030, 1, 2, 9)), isTrue);
      expect(
        lapsedItems([voice], DateTime.utc(2030, 1, 2, 8, 59)).toSkip,
        isEmpty,
      );
      expect(lapsedItems([voice], DateTime.utc(2030, 1, 2, 9)).toSkip, [voice]);
    });

    test('a default alarm keeps the end-of-day deadline', () {
      expect(
        responseDeadlineUtc(_item(voiceNote: null, at: at)),
        DateTime.utc(2030, 1, 2),
      );
    });
  });

  testWidgets('labels: Heard / Heard (Late) / Missed; alarms unchanged', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    const done = ScheduleOutcome(result: OutcomeResult.done);
    const lapsed = ScheduleOutcome(
      result: OutcomeResult.skipped,
      skipReason: kLapsedSkipReason,
    );
    final rangOut = ScheduleAlarmTimeline(
      unavailableAt: DateTime.utc(2030, 1, 1, 9, 1),
    );
    String label(ScheduleItem i) => itemOutcomeStyle(ctx, i).label;

    expect(label(_item(outcome: done)), 'Heard');
    expect(label(_item(outcome: done, alarm: rangOut)), 'Heard (Late)');
    expect(label(_item(outcome: lapsed)), 'Missed');
    expect(label(_item(voiceNote: null, outcome: done)), 'Done');
    expect(
      label(_item(voiceNote: null, outcome: done, alarm: rangOut)),
      'Done (Late)',
    );
    expect(label(_item(voiceNote: null, outcome: lapsed)), 'Skipped');
  });

  group('dismissed while ringing = heard', () {
    final dismissed = ScheduleAlarmTimeline(
      dismissedAt: DateTime.utc(2030, 1, 1, 9),
    );

    test('only open, dismissed voice notes of mine qualify', () {
      final heard = _item(id: 'a', alarm: dismissed);
      final items = [
        heard,
        _item(id: 'b'), // not dismissed
        _item(id: 'c', voiceNote: null, alarm: dismissed), // default alarm
        _item(
          id: 'd',
          alarm: dismissed,
          outcome: const ScheduleOutcome(result: OutcomeResult.done),
        ),
      ];
      expect(voiceNotesHeardByDismiss(items, 'me'), [heard]);
      expect(voiceNotesHeardByDismiss(items, 'someone-else'), isEmpty);
    });

    test('the reconciler closes it as Done, once, with no push', () async {
      final repo = _Repo();
      final reconciler = VoiceHeardReconciler(repo);
      final closed = await reconciler.reconcile('me', [
        _item(alarm: dismissed),
      ]);
      expect(closed, 1);
      expect(repo.done, ['me/v/planner']);
    });
  });

  Future<(_Repo, _Notifier, _Player)> pumpCard(
    WidgetTester tester,
    ScheduleItem item,
  ) async {
    final repo = _Repo();
    final notifier = _Notifier();
    final player = _Player();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          profileByUidProvider.overrideWith(
            (ref, uid) => Stream.value(
              UserProfile(uid: uid, name: 'Name $uid', homeTimezone: 'Etc/UTC'),
            ),
          ),
          scheduleRepositoryProvider.overrideWithValue(repo),
          notificationEventNotifierProvider.overrideWithValue(notifier),
          voiceNoteCacheProvider.overrideWithValue(_Cache()),
          voicePlayerProvider.overrideWithValue(player),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ListView(children: [OutcomeCard(item: item)]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (repo, notifier, player);
  }

  testWidgets('before it rings a voice card has nothing to answer', (
    tester,
  ) async {
    await pumpCard(
      tester,
      _item(at: DateTime.now().toUtc().add(const Duration(hours: 2))),
    );
    expect(find.text('Done'), findsNothing);
    expect(find.text('Skip'), findsNothing);
    expect(find.text('Play'), findsNothing);
    expect(find.text('Already heard'), findsNothing);
  });

  for (final play in [false, true]) {
    testWidgets(
      'a rung voice card: ${play ? 'Play' : 'Already heard'} closes it and '
      'tells the planner — never Done/Skip',
      (tester) async {
        final (repo, notifier, player) = await pumpCard(
          tester,
          _item(at: DateTime.now().toUtc().subtract(const Duration(hours: 1))),
        );
        expect(find.text('Done'), findsNothing);
        expect(find.text('Skip'), findsNothing);
        await tester.tap(
          find.byKey(ValueKey(play ? 'voice-play-v' : 'voice-already-heard-v')),
        );
        await tester.pump();
        await tester.pump(kPlannerUpdateDuration);
        await tester.pumpAndSettle();
        expect(repo.done, ['me/v/planner']);
        expect(notifier.events, [NotifyEvent.outcome]);
        expect(player.played, play ? ['/voice/v.m4a'] : isEmpty);
      },
    );
  }

  testWidgets('a default alarm keeps Done/Skip', (tester) async {
    await pumpCard(
      tester,
      _item(
        voiceNote: null,
        at: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      ),
    );
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    expect(find.text('Already heard'), findsNothing);
  });
}
