import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/outcomes/presentation/outcome_screen.dart';
import 'package:time_app/features/outcomes/presentation/reply_note.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/presentation/planner_activity_screen.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// R6 (2026-10-02): the target's optional note to the planner. "Send note"
/// beside the answers; one note, no edits, its own push; "Note" on History.

const _voice = VoiceNoteMeta(
  durationMs: 5000,
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  sizeBytes: 100,
);

ScheduleItem _item({
  String id = 'p1',
  String createdByUid = 'planner',
  ScheduleItemStatus status = ScheduleItemStatus.approved,
  ScheduleOutcome? outcome,
  ScheduleReply? reply,
  VoiceNoteMeta? voiceNote,
  Duration dueIn = const Duration(hours: -1),
}) => ScheduleItem(
  id: id,
  targetUid: 'me',
  createdByUid: createdByUid,
  groupId: '',
  title: voiceNote == null ? 'Walk' : 'Voice alarm',
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: DateTime.now().toUtc().add(dueIn),
  status: status,
  outcome: outcome,
  reply: reply,
  voiceNote: voiceNote,
);

class _Repo implements ScheduleRepository {
  _Repo({this.fail = false});

  final bool fail;
  final replies = <String>[];

  @override
  Future<void> sendReply(String targetUid, String itemId, String text) async {
    if (fail) throw StateError('offline');
    replies.add('$targetUid/$itemId/$text');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifier implements NotificationEventNotifier {
  final events = <(NotifyEvent, String)>[];

  @override
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async => events.add((event, itemId));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(_Repo, _Notifier)> _pump(
  WidgetTester tester,
  Widget card, {
  _Repo? repo,
}) async {
  final r = repo ?? _Repo();
  final notifier = _Notifier();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUidProvider.overrideWithValue('me'),
        profileByUidProvider.overrideWith(
          (ref, uid) => Stream.value(
            UserProfile(uid: uid, name: 'Name $uid', homeTimezone: 'Etc/UTC'),
          ),
        ),
        scheduleRepositoryProvider.overrideWithValue(r),
        notificationEventNotifierProvider.overrideWithValue(notifier),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: ListView(children: [card])),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (r, notifier);
}

final _sendNote = find.text('Send note');

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('rules of the button', () {
    test('only on someone else\'s live, unanswered plan with no note', () {
      expect(_item().canSendReply, isTrue);
      expect(_item(createdByUid: 'me').canSendReply, isFalse, reason: 'self');
      expect(
        _item(
          outcome: const ScheduleOutcome(result: OutcomeResult.done),
        ).canSendReply,
        isFalse,
        reason: 'answered: no note after Skip/Done',
      );
      expect(
        _item(reply: const ScheduleReply(text: 'Hi')).canSendReply,
        isFalse,
        reason: 'one note only',
      );
      expect(_item(status: ScheduleItemStatus.withdrawn).canSendReply, isFalse);
    });

    test('a stored note is read trimmed; a blank one is no note', () {
      expect(
        ScheduleReply.fromMap({'text': '  On my way '})!.text,
        'On my way',
      );
      expect(ScheduleReply.fromMap({'text': '   '}), isNull);
      expect(ScheduleReply.fromMap(null), isNull);
      expect(ScheduleReply.fromMap({'text': 7}), isNull);
    });

    test('the prompt says it is optional, who it goes to, and about what', () {
      expect(
        sendNotePrompt(_item(), plannerName: 'Test Planner'),
        'Optional: send a note to Test Planner about this alarm.',
      );
      expect(
        sendNotePrompt(_item(voiceNote: _voice), plannerName: 'Test Planner'),
        'Optional: send a note to Test Planner about this voice note.',
      );
      expect(
        sendNotePrompt(_item()),
        'Optional: send a note to your planner about this alarm.',
      );
    });
  });

  group('Home card', () {
    testWidgets('a friend\'s alarm reads Skip · Send note · Done, in order', (
      tester,
    ) async {
      await _pump(tester, OutcomeCard(item: _item()));
      expect(_sendNote, findsOneWidget);
      final skip = tester.getCenter(find.text('Skip')).dx;
      final note = tester.getCenter(_sendNote).dx;
      final done = tester.getCenter(find.text('Done')).dx;
      expect(skip, lessThan(note));
      expect(note, lessThan(done));
    });

    testWidgets('a self-plan has no Send note', (tester) async {
      await _pump(tester, OutcomeCard(item: _item(createdByUid: 'me')));
      expect(find.text('Done'), findsOneWidget);
      expect(_sendNote, findsNothing);
    });

    testWidgets('a rung voice note: Already heard · Send note · Play', (
      tester,
    ) async {
      await _pump(tester, OutcomeCard(item: _item(voiceNote: _voice)));
      expect(find.text('Already heard'), findsOneWidget);
      expect(_sendNote, findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
    });

    testWidgets('sending: the prompt, Send only with text, saved trimmed, '
        'then the planner is told', (tester) async {
      final (repo, notifier) = await _pump(tester, OutcomeCard(item: _item()));
      await tester.tap(_sendNote);
      await tester.pumpAndSettle();
      expect(
        find.text('Optional: send a note to Name planner about this alarm.'),
        findsOneWidget,
      );
      final send = find.byKey(const ValueKey('send-note-send'));
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('send-note-text')),
        '   ',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('send-note-text')),
        '  Running late  ',
      );
      await tester.pump();
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(repo.replies, ['me/p1/Running late']);
      expect(notifier.events, [(NotifyEvent.replied, 'p1')]);
      expect(find.text('Send note'), findsWidgets); // card unchanged until echo
      expect(find.byKey(const ValueKey('send-note-text')), findsNothing);
    });

    testWidgets('Cancel sends nothing', (tester) async {
      final (repo, notifier) = await _pump(tester, OutcomeCard(item: _item()));
      await tester.tap(_sendNote);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.replies, isEmpty);
      expect(notifier.events, isEmpty);
    });

    testWidgets('a failed save says so, keeps the text, and tells nobody', (
      tester,
    ) async {
      final (_, notifier) = await _pump(
        tester,
        OutcomeCard(item: _item()),
        repo: _Repo(fail: true),
      );
      await tester.tap(_sendNote);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('send-note-text')),
        'Hi',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-note-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('send-note-error')), findsOneWidget);
      expect(find.text('Hi'), findsOneWidget);
      expect(notifier.events, isEmpty);
    });

    testWidgets('the note box is capped at 200 characters', (tester) async {
      await _pump(tester, OutcomeCard(item: _item()));
      await tester.tap(_sendNote);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('send-note-text')),
      );
      expect(field.maxLength, ScheduleReply.maxLength);
      expect(ScheduleReply.maxLength, 200);
    });
  });

  group('History cards', () {
    const done = ScheduleOutcome(result: OutcomeResult.done);
    final note = find.text('Note');

    testWidgets('mine with a note: Note opens "Your note"', (tester) async {
      await _pump(
        tester,
        OutcomeCard(
          item: _item(
            outcome: done,
            reply: const ScheduleReply(text: 'Took the long route'),
          ),
        ),
      );
      expect(_sendNote, findsNothing, reason: 'no note after an answer');
      await tester.tap(note);
      await tester.pumpAndSettle();
      expect(find.text('Your note'), findsOneWidget);
      expect(find.text('Took the long route'), findsOneWidget);
    });

    testWidgets('no note sent: no Note button, and none after answering', (
      tester,
    ) async {
      await _pump(tester, OutcomeCard(item: _item(outcome: done)));
      expect(note, findsNothing);
      expect(_sendNote, findsNothing);
    });

    testWidgets('the planner\'s answered card: Note from {name}', (
      tester,
    ) async {
      final mine = ScheduleItem(
        id: 'p2',
        targetUid: 'friend',
        createdByUid: 'me',
        groupId: '',
        title: 'Walk',
        localWallTime: '',
        timezone: 'Etc/UTC',
        scheduledInstantUtc: DateTime.now().toUtc(),
        status: ScheduleItemStatus.approved,
        outcome: done,
        reply: const ScheduleReply(text: 'All done'),
      );
      await _pump(tester, PlannerItemCard(item: mine));
      await tester.tap(note);
      await tester.pumpAndSettle();
      expect(find.text('Note from Name friend'), findsOneWidget);
      expect(find.text('All done'), findsOneWidget);
    });

    testWidgets('the planner\'s card shows no Note while the plan is open', (
      tester,
    ) async {
      final open = ScheduleItem(
        id: 'p3',
        targetUid: 'friend',
        createdByUid: 'me',
        groupId: '',
        title: 'Walk',
        localWallTime: '',
        timezone: 'Etc/UTC',
        scheduledInstantUtc: DateTime.now().toUtc(),
        status: ScheduleItemStatus.approved,
        reply: const ScheduleReply(text: 'Soon'),
      );
      await _pump(tester, PlannerItemCard(item: open));
      expect(note, findsNothing);
    });
  });
}
