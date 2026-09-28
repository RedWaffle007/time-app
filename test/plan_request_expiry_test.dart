import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/widgets/section_header.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/plan_requests/application/plan_request_providers.dart';
import 'package:time_app/features/plan_requests/domain/plan_request.dart';
import 'package:time_app/features/plan_requests/presentation/plan_request_screens.dart';
import 'package:time_app/routing/app_router.dart';
import 'package:time_app/routing/notification_routing.dart';

/// 2026-09-28: a plan request closes as `expired` once its time passes
/// unplanned; the Request tab lists only live requests and a HISTORY button
/// opens every finished one (set / declined / cancelled / expired).

final _future = DateTime.utc(2030, 10, 5, 1);
final _past = DateTime.utc(2020, 3, 5, 1);

PlanRequest _request({
  required String id,
  DateTime? at,
  PlanRequestStatus status = PlanRequestStatus.pending,
  String requester = 'friend',
  String planner = 'me',
  String title = 'Task',
}) {
  final start = at ?? _future;
  return PlanRequest(
    id: id,
    batchId: 'b',
    requesterUid: requester,
    plannerUid: planner,
    mode: PlanRequestMode.onePlan,
    status: status,
    timezone: 'UTC',
    windowStartUtc: start,
    windowEndUtc: start.add(const Duration(minutes: 1)),
    durationMinutes: 1,
    title: title,
  );
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('domain', () {
    test('a one-plan request is live until its minute', () {
      final r = _request(id: 'r', at: DateTime.utc(2030, 1, 1, 12));
      expect(r.lastStartUtc, DateTime.utc(2030, 1, 1, 12));
      expect(r.isLiveAt(DateTime.utc(2030, 1, 1, 11, 59)), isTrue);
      expect(r.isLiveAt(DateTime.utc(2030, 1, 1, 12)), isFalse);
      expect(
        r.statusAt(DateTime.utc(2030, 1, 1, 12)),
        PlanRequestStatus.expired,
      );
      expect(
        r.statusAt(DateTime.utc(2030, 1, 1, 11)),
        PlanRequestStatus.pending,
      );
    });

    test('a finished request keeps its own status past its time', () {
      for (final status in [
        PlanRequestStatus.fulfilled,
        PlanRequestStatus.declined,
        PlanRequestStatus.cancelled,
        PlanRequestStatus.expired,
      ]) {
        final r = _request(id: 'r', at: _past, status: status);
        expect(r.isLiveAt(DateTime.utc(2030)), isFalse);
        expect(r.statusAt(DateTime.utc(2030)), status);
      }
    });

    test('a legacy flexible window is live until its last fitting start', () {
      final r = PlanRequest(
        id: 'f',
        batchId: 'b',
        requesterUid: 'friend',
        plannerUid: 'me',
        mode: PlanRequestMode.flexibleWindow,
        status: PlanRequestStatus.inProgress,
        timezone: 'UTC',
        windowStartUtc: DateTime.utc(2030, 1, 1, 10),
        windowEndUtc: DateTime.utc(2030, 1, 1, 12),
        durationMinutes: 30,
      );
      expect(r.lastStartUtc, DateTime.utc(2030, 1, 1, 11, 30));
      expect(r.isLiveAt(DateTime.utc(2030, 1, 1, 11)), isTrue);
      expect(r.isLiveAt(DateTime.utc(2030, 1, 1, 11, 30)), isFalse);
    });

    test('expired parses; unknown statuses still read as pending', () {
      expect(PlanRequestStatus.values.map((s) => s.name), contains('expired'));
    });

    test('History = every finished request, newest time first, once', () {
      final now = DateTime.utc(2025);
      final a = _request(
        id: 'a',
        at: DateTime.utc(2024, 1, 1),
        status: PlanRequestStatus.fulfilled,
      );
      final b = _request(
        id: 'b',
        at: DateTime.utc(2024, 6, 1),
        status: PlanRequestStatus.declined,
      );
      final c = _request(
        id: 'c',
        at: DateTime.utc(2024, 3, 1),
        status: PlanRequestStatus.cancelled,
      );
      final d = _request(
        id: 'd',
        at: DateTime.utc(2024, 2, 1),
        status: PlanRequestStatus.expired,
      );
      final pastOpen = _request(id: 'e', at: DateTime.utc(2024, 4, 1));
      final live = _request(id: 'f', at: DateTime.utc(2026));
      final result = finishedPlanRequests([a, b, c, d, pastOpen, live, a], now);
      expect(result.map((r) => r.id), ['b', 'e', 'c', 'd', 'a']);
    });
  });

  test('status labels read from the viewer side', () {
    String l(PlanRequestStatus s, bool incoming) =>
        planRequestStatusLabel(s, incoming: incoming);
    expect(l(PlanRequestStatus.fulfilled, true), 'You set the alarm');
    expect(l(PlanRequestStatus.fulfilled, false), 'Alarm set');
    expect(l(PlanRequestStatus.declined, true), 'You declined');
    expect(l(PlanRequestStatus.declined, false), 'Declined');
    expect(l(PlanRequestStatus.cancelled, true), 'They cancelled');
    expect(l(PlanRequestStatus.cancelled, false), 'You cancelled');
    expect(l(PlanRequestStatus.expired, true), 'Missed: the time passed');
    expect(l(PlanRequestStatus.expired, false), 'Not set: the time passed');
  });

  test('the badge never counts a request whose time passed', () {
    final container = ProviderContainer(
      overrides: [
        incomingPlanRequestsProvider.overrideWithValue(
          AsyncData([_request(id: 'live'), _request(id: 'past', at: _past)]),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(incomingPlanRequestCountProvider), 1);
  });

  Future<GoRouter> pumpRequests(
    WidgetTester tester, {
    required List<PlanRequest> received,
    required List<PlanRequest> sent,
  }) async {
    final router = GoRouter(
      initialLocation: Routes.requests,
      routes: [
        GoRoute(
          path: Routes.requests,
          builder: (_, _) => const PlanRequestsScreen(),
          routes: [
            GoRoute(
              path: 'history',
              builder: (_, _) => const PlanRequestHistoryScreen(),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    final open = [
      for (final r in received)
        if (r.isOpen) r,
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          incomingPlanRequestsProvider.overrideWith(
            (ref) => Stream.value(open),
          ),
          receivedPlanRequestsProvider.overrideWith(
            (ref) => Stream.value(received),
          ),
          outgoingPlanRequestsProvider.overrideWith(
            (ref) => Stream.value(sent),
          ),
          profileByUidProvider.overrideWith((ref, uid) => Stream.value(null)),
        ],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('the Request tab hides requests whose time passed', (
    tester,
  ) async {
    await pumpRequests(
      tester,
      received: [
        _request(id: 'in-live', title: 'Live in'),
        _request(id: 'in-past', at: _past, title: 'Past in'),
      ],
      sent: [
        _request(
          id: 'out-live',
          requester: 'me',
          planner: 'friend',
          title: 'Live out',
        ),
        _request(
          id: 'out-past',
          requester: 'me',
          planner: 'friend',
          at: _past,
          title: 'Past out',
        ),
        _request(
          id: 'out-done',
          requester: 'me',
          planner: 'friend',
          status: PlanRequestStatus.fulfilled,
          title: 'Done out',
        ),
      ],
    );
    expect(find.text('Live in'), findsOneWidget);
    expect(find.text('Live out'), findsOneWidget);
    expect(find.text('Past in'), findsNothing);
    expect(find.text('Past out'), findsNothing);
    expect(find.text('Done out'), findsNothing);
    expect(find.text('HISTORY'), findsOneWidget);
  });

  testWidgets('HISTORY shows every finished request with how it ended', (
    tester,
  ) async {
    await pumpRequests(
      tester,
      received: [
        _request(id: 'in-live', title: 'Live in'),
        _request(
          id: 'in-expired',
          at: DateTime.utc(2024, 5, 10, 12),
          status: PlanRequestStatus.expired,
          title: 'Expired in',
        ),
      ],
      sent: [
        _request(
          id: 'out-set',
          requester: 'me',
          planner: 'friend',
          at: DateTime.utc(2024, 7, 10, 12),
          status: PlanRequestStatus.fulfilled,
          title: 'Set out',
        ),
        _request(
          id: 'out-past-open',
          requester: 'me',
          planner: 'friend',
          at: DateTime.utc(2024, 6, 10, 12),
          title: 'Unmarked out',
        ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('request-history')));
    await tester.pumpAndSettle();

    expect(find.text('Request History'), findsOneWidget);
    expect(find.text('Live in'), findsNothing);
    expect(find.text('Set out'), findsOneWidget);
    expect(find.text('Expired in'), findsOneWidget);
    expect(find.text('Unmarked out'), findsOneWidget);
    expect(find.text('Alarm set'), findsOneWidget);
    expect(find.text('Missed: the time passed'), findsOneWidget);
    // Past its time before the Worker marked it: already reads as expired.
    expect(find.text('Not set: the time passed'), findsOneWidget);
    // No actions in History.
    expect(find.text('Cancel request'), findsNothing);
    expect(find.text('Decline'), findsNothing);
    // Newest first, under month headers.
    final set = tester.getTopLeft(find.text('Set out')).dy;
    final unmarked = tester.getTopLeft(find.text('Unmarked out')).dy;
    final expired = tester.getTopLeft(find.text('Expired in')).dy;
    expect(set, lessThan(unmarked));
    expect(unmarked, lessThan(expired));
    // July, June, May 2024: one header each.
    expect(find.byType(SectionHeader), findsNWidgets(3));
  });

  testWidgets('an expiry push opens Request History', (tester) async {
    final router = GoRouter(
      initialLocation: Routes.plan,
      routes: [
        GoRoute(path: Routes.plan, builder: (_, _) => const Text('Plan')),
        GoRoute(
          path: Routes.requests,
          builder: (_, _) => const Text('Requests'),
          routes: [
            GoRoute(
              path: 'history',
              builder: (_, _) => const Text('Request History'),
            ),
          ],
        ),
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
      'event': 'planRequestExpired',
      'planRequestId': 'b_me',
    });
    await tester.pumpAndSettle();
    expect(find.text('Request History'), findsOneWidget);
  });
}
