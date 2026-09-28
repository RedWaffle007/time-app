import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/theme/app_tokens.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/notifications/application/friend_notifier.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/plan_requests/application/plan_request_providers.dart';
import 'package:time_app/features/plan_requests/data/plan_request_repository.dart';
import 'package:time_app/features/plan_requests/domain/plan_request.dart';
import 'package:time_app/features/plan_requests/presentation/plan_request_screens.dart';
import 'package:time_app/features/scheduling/application/schedule_clash.dart';
import 'package:time_app/features/scheduling/application/schedule_providers.dart';
import 'package:time_app/features/scheduling/data/schedule_repository.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/social/application/social_providers.dart';

/// Batch G item 5 (2026-09-27): Request Plan redesigned — one friend, one
/// minute, a task, an optional note; the friend sets the alarm.

class _Repo implements PlanRequestRepository {
  final created = <Map<String, Object?>>[];
  final fulfilled = <Map<String, Object?>>[];
  final declined = <String>[];
  Object? fulfilFails;

  @override
  Future<String> createRequest({
    required String requesterUid,
    required String plannerUid,
    required String timezone,
    required DateTime instantUtc,
    required String task,
    String? note,
  }) async {
    created.add({
      'requester': requesterUid,
      'planner': plannerUid,
      'zone': timezone,
      'instant': instantUtc,
      'task': task,
      'note': note,
    });
    return 'req-1';
  }

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
    final failure = fulfilFails;
    if (failure != null) throw failure;
    fulfilled.add({
      'title': title,
      'note': note,
      'wall': wall,
      'duration': durationMinutes,
    });
    return 'item-1';
  }

  @override
  Future<void> decline(PlanRequest request) async => declined.add(request.id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

var _lastFriends = _Friends();

class _Friends implements FriendEventNotifier {
  final sent = <(FriendNotifyEvent, String, String?)>[];

  @override
  Future<void> notify({
    required FriendNotifyEvent event,
    required String fromUid,
    required String toUid,
    String? kind,
    String? planRequestId,
    String? groupId,
  }) async => sent.add((event, toUid, planRequestId));
}

class _Items implements NotificationEventNotifier {
  @override
  Future<NotificationDeliveryResult> notifyConfirmed({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async => const NotificationDeliveryResult(delivered: true, reason: 'sent');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Schedule implements ScheduleRepository {
  String? holder;

  @override
  Future<String?> minuteLockHolder(
    String targetUid,
    DateTime instantUtc,
  ) async => holder;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// 2030-10-04 16:00Z = 09:00 PDT in Vancouver.
final _now = DateTime.utc(2030, 10, 4, 16);
const _zone = 'America/Vancouver';

UserProfile _profile(String uid) =>
    UserProfile(uid: uid, name: 'Name $uid', homeTimezone: _zone);

ScheduleItem _busyAt(DateTime at) => ScheduleItem(
  id: 'busy',
  targetUid: 'me',
  createdByUid: 'me',
  groupId: '',
  title: 'Own plan',
  localWallTime: '',
  timezone: _zone,
  scheduledInstantUtc: at,
  status: ScheduleItemStatus.approved,
);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('the form', () {
    Future<(_Repo, _Friends)> open(
      WidgetTester tester, {
      List<ScheduleItem> mine = const [],
    }) async {
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final repo = _Repo();
      final friends = _Friends();
      final router = GoRouter(
        initialLocation: '/start',
        routes: [
          GoRoute(
            path: '/start',
            builder: (_, _) => const Text('Start'),
            routes: [
              GoRoute(
                path: 'request',
                builder: (_, _) => const CreatePlanRequestScreen(),
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUidProvider.overrideWithValue('me'),
            profileProvider.overrideWith((ref) => Stream.value(_profile('me'))),
            myFriendUidsProvider.overrideWithValue(
              const AsyncData(['alex', 'sam']),
            ),
            profileByUidProvider.overrideWith(
              (ref, uid) => Stream.value(_profile(uid)),
            ),
            planRequestRepositoryProvider.overrideWithValue(repo),
            friendEventNotifierProvider.overrideWithValue(friends),
            scheduleClashCheckerProvider.overrideWithValue(
              ScheduleClashChecker(fetch: (_) async => mine),
            ),
          ],
          child: MaterialApp.router(
            theme: AppTheme.light,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      router.push('/start/request');
      await tester.pumpAndSettle();
      return (repo, friends);
    }

    bool sendEnabled(WidgetTester tester) =>
        tester
            .widget<ButtonStyleButton>(
              find.byKey(const ValueKey('request-send')),
            )
            .onPressed !=
        null;

    Future<void> pickDefaults(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('request-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('request-time')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }

    testWidgets('exactly one friend can be chosen', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await open(tester);
        await tester.tap(find.byKey(const ValueKey('request-friend-alex')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('request-friend-sam')));
        await tester.pumpAndSettle();
        final radios = tester
            .widgetList<RadioListTile<String>>(
              find.byType(RadioListTile<String>),
            )
            .toList();
        expect(radios, hasLength(2));
        // Nothing to toggle per row: one group value decides the one choice.
        expect(find.byType(Checkbox), findsNothing);
      });
    });

    testWidgets('Send stays off until friend, date and time are chosen', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        await open(tester);
        expect(sendEnabled(tester), isFalse);
        await tester.tap(find.byKey(const ValueKey('request-friend-alex')));
        await tester.pumpAndSettle();
        expect(sendEnabled(tester), isFalse);
        await pickDefaults(tester);
        expect(sendEnabled(tester), isTrue);
      });
    });

    testWidgets('the task is mandatory, in red', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final (repo, _) = await open(tester);
        await tester.tap(find.byKey(const ValueKey('request-friend-alex')));
        await tester.pumpAndSettle();
        await pickDefaults(tester);
        await tester.tap(find.byKey(const ValueKey('request-send')));
        await tester.pumpAndSettle();
        expect(
          find.text('Please write the task. It is mandatory.'),
          findsOneWidget,
        );
        expect(repo.created, isEmpty);
      });
    });

    testWidgets('a minute you already have a plan at blocks Send', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        // The pickers open on "now" in your zone: 09:00 PDT = 16:00Z.
        await open(tester, mine: [_busyAt(_now)]);
        await tester.tap(find.byKey(const ValueKey('request-friend-alex')));
        await tester.pumpAndSettle();
        await pickDefaults(tester);
        expect(
          find.text(
            'You already have a plan scheduled for this time. '
            'Please select a different time.',
          ),
          findsOneWidget,
        );
        expect(sendEnabled(tester), isFalse);
      });
    });

    testWidgets('Send asks ONE friend for ONE minute and pushes them', (
      tester,
    ) async {
      final future = DateTime.utc(2030, 10, 5, 1); // 18:00 PDT on Oct 4
      await withClock(Clock.fixed(_now), () async {
        final (repo, friends) = await open(tester);
        await tester.tap(find.byKey(const ValueKey('request-friend-sam')));
        await tester.pumpAndSettle();
        await pickDefaults(tester);
        await tester.enterText(
          find.byKey(const ValueKey('request-task')),
          'Take medicine',
        );
        await tester.enterText(
          find.byKey(const ValueKey('request-note')),
          'After dinner',
        );
        await tester.pumpAndSettle();
        // The default is "now" — move it to 6 PM so it lies ahead.
        await tester.tap(find.byKey(const ValueKey('request-time')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Switch to text input mode'));
        await tester.pumpAndSettle();
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(fields.evaluate().length - 2), '6');
        await tester.enterText(fields.last, '00');
        await tester.pumpAndSettle();
        if (find.text('PM').evaluate().isNotEmpty) {
          await tester.tap(find.text('PM'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('request-send')));
        await tester.pumpAndSettle();

        expect(repo.created, hasLength(1));
        final req = repo.created.single;
        expect(req['planner'], 'sam');
        expect(req['task'], 'Take medicine');
        expect(req['note'], 'After dinner');
        expect(req['zone'], _zone);
        expect(req['instant'], future);
        expect(friends.sent.single, (
          FriendNotifyEvent.planRequested,
          'sam',
          'req-1',
        ));
        expect(find.text('Start'), findsOneWidget);
      });
    });
  });

  group('the friend\'s side', () {
    final request = PlanRequest(
      id: 'req-1',
      batchId: 'b',
      requesterUid: 'alex',
      plannerUid: 'me',
      mode: PlanRequestMode.onePlan,
      status: PlanRequestStatus.pending,
      timezone: _zone,
      windowStartUtc: DateTime.utc(2030, 10, 5, 1),
      windowEndUtc: DateTime.utc(2030, 10, 5, 1, 1),
      durationMinutes: 1,
      title: 'Take medicine',
      message: 'After dinner',
    );

    Future<(_Repo, _Schedule)> open(
      WidgetTester tester, [
      PlanRequest? value,
    ]) async {
      _lastFriends = _Friends();
      final repo = _Repo();
      final schedule = _Schedule();
      final router = GoRouter(
        initialLocation: '/start',
        routes: [
          GoRoute(
            path: '/start',
            builder: (_, _) => const Text('Start'),
            routes: [
              GoRoute(
                path: 'fulfil',
                builder: (_, _) =>
                    const FulfillPlanRequestScreen(requestId: 'req-1'),
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUidProvider.overrideWithValue('me'),
            planRequestProvider.overrideWith(
              (ref, id) => Stream.value(value ?? request),
            ),
            profileByUidProvider.overrideWith(
              (ref, uid) => Stream.value(_profile(uid)),
            ),
            planRequestRepositoryProvider.overrideWithValue(repo),
            scheduleRepositoryProvider.overrideWithValue(schedule),
            notificationEventNotifierProvider.overrideWithValue(_Items()),
            friendEventNotifierProvider.overrideWithValue(_lastFriends),
          ],
          child: MaterialApp.router(
            theme: AppTheme.light,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      router.push('/start/fulfil');
      await tester.pumpAndSettle();
      return (repo, schedule);
    }

    testWidgets('shows who, what, when and the note', (tester) async {
      await open(tester);
      expect(
        find.text('Name alex has requested you to plan for them.'),
        findsOneWidget,
      );
      expect(find.text('Take medicine'), findsOneWidget);
      expect(find.text('After dinner'), findsOneWidget);
      expect(find.textContaining(_zone), findsOneWidget);
      expect(find.text('Set the alarm'), findsOneWidget);
    });

    test('Set the alarm opens the normal Plan screen for this request '
        '(item 5b)', () {
      final screen = File(
        'lib/features/plan_requests/presentation/plan_request_screens.dart',
      ).readAsStringSync();
      expect(
        screen,
        contains('ScheduleBuilderScreen(planRequest: request)'),
      );
      // The request screen itself no longer writes a plan.
      expect(screen, isNot(contains('.fulfill(')));
    });

    testWidgets('Decline declines and tells the requester (Uh-Oh)', (
      tester,
    ) async {
      final (repo, _) = await open(tester);
      await tester.tap(find.byKey(const ValueKey('request-decline')));
      await tester.pumpAndSettle();
      expect(repo.declined, ['req-1']);
      expect(_lastFriends.sent, [
        (FriendNotifyEvent.planRequestDeclined, 'me', 'req-1'),
      ]);
    });

    testWidgets('a planned request offers no action', (tester) async {
      await open(
        tester,
        PlanRequest(
          id: 'req-1',
          batchId: 'b',
          requesterUid: 'alex',
          plannerUid: 'me',
          mode: PlanRequestMode.onePlan,
          status: PlanRequestStatus.fulfilled,
          timezone: _zone,
          windowStartUtc: DateTime.utc(2030, 10, 5, 1),
          windowEndUtc: DateTime.utc(2030, 10, 5, 1, 1),
          durationMinutes: 1,
          title: 'Take medicine',
        ),
      );
      expect(find.text('The alarm is set.'), findsOneWidget);
      expect(find.text('Set the alarm'), findsNothing);
    });
  });

  test('the FAB theme makes PLAN / REQUEST PLAN taller and bold', () {
    final fab = AppTheme.light.floatingActionButtonTheme;
    expect(fab.extendedTextStyle?.fontWeight, FontWeight.w700);
    expect(fab.extendedSizeConstraints?.minHeight, Sizes.createFab);
    expect(Sizes.createFab, greaterThan(56));
  });
}
