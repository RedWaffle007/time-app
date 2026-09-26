import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../dev/dev_menu_screen.dart';
import '../features/archive/presentation/archived_screen.dart';
import '../features/auth/application/auth_providers.dart';
import '../features/auth/presentation/auth_screen.dart';
import '../features/groups/presentation/group_detail_screen.dart';
import '../features/groups/presentation/group_progress_screen.dart';
import '../features/auth/presentation/profile_edit_screen.dart';
import '../features/calendar/presentation/calendar_screen.dart';
import '../features/home/presentation/home_gate.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/outcomes/presentation/history_screen.dart';
import '../features/plan_requests/presentation/plan_request_screens.dart';
import '../features/walkthrough/presentation/how_it_works_screen.dart';
import '../features/social/presentation/blocked_users_screen.dart';
import '../features/social/presentation/friend_requests_screen.dart';
import '../features/social/presentation/friends_screen.dart';
import '../features/social/presentation/user_profile_screen.dart';
import '../features/social/presentation/user_search_screen.dart';
import '../features/home/presentation/home_shell.dart';
import '../features/reminders/presentation/alarm_screen.dart';
import '../features/reminders/presentation/reminder_diagnostics_screen.dart';
import '../features/scheduling/presentation/schedule_builder_screen.dart';
import '../features/home/presentation/you_screen.dart';
import '../features/plan/presentation/plan_shell.dart';
import '../features/stats/presentation/stats_screen.dart';
import '../features/time_tracking/presentation/track_screen.dart';
import '../features/voice_notes/presentation/voice_library_screen.dart';
import 'go_router_refresh_stream.dart';
import '../features/invites/application/pending_invite.dart';
import '../features/invites/domain/invite_link.dart';

/// Central list of route paths/names, so screens don't hardcode strings.
///
/// Since the S5 cutover the five pillar roots are `/plan`, `/track`, `/stats`
/// and `/you` (the ⊕ voice FAB is not a route). A route that belongs *to* a
/// pillar is nested under its path, so its location names the branch it lives in
/// — `go()` from a notification lands inside the right pillar with the bottom bar
/// and a back stack, not on a bare screen. Account-level routes (`/profile`,
/// `/archived`, `/calendar`, `/dev`) stay top-level; Friends lives under You so
/// notification entry has a main-tab route underneath it. The three old
/// delegation stances live as sub-tabs inside `/plan` (see [plan]).
class Routes {
  static const home = '/'; // HomeGate: profile-completion or app home.
  static const auth = '/auth';
  static const profile = '/profile';
  static const archived = '/archived';

  /// **Permissions onboarding**, re-runnable from the account menu. Top-level
  /// and pushed, like [profile] and [archived] — it belongs to no tab. The
  /// first-run flow reaches the same screen inline through `OnboardingGate`;
  /// this route is the "review / fix my permissions" door after that.
  static const permissions = '/permissions';

  /// **The "How this app works" guide** — a complete, scrollable reference with
  /// one blurb per page and feature. Top-level and pushed, reached from the
  /// account menu; it belongs to no tab. Distinct from the first-run coach tour,
  /// which it can replay.
  static const howItWorks = '/how-it-works';

  /// **The calendar** — a month/week/day view over the items that already
  /// exist. Top-level and pushed from My Schedule's `CALENDAR` control. It
  /// merges the items you are the TARGET of with the ones you planned for
  /// others, so it belongs to no single tab. It is
  /// deliberately not a fourth nav destination — the bar's three tabs are the
  /// three stances in the delegation loop, and a calendar is a lens over all
  /// three rather than a fourth one (DECISIONS.md → "In-app calendar").
  static const calendar = '/calendar';

  /// Planning an item from a tapped date.
  ///
  /// This is the REAL [ScheduleBuilderScreen], not a parallel create flow — the
  /// calendar's whole integration with the builder is one optional
  /// `initialDate`. It is a sub-route of [calendar] for the same reason
  /// `/you/friends/search` is a sub-route of `/you/friends`: the calendar is
  /// pushed at the root, so its create flow belongs to its own stack and Back
  /// returns to the grid.
  ///
  /// It is a SECOND registration of that screen, and that is examined rather
  /// than assumed. D2 was three screens registered as tabs *and* as flat
  /// top-level paths, where the harm was a notification `go()` becoming
  /// ambiguous about which stack it meant. Nothing deep-links to the builder,
  /// and the alternative — pushing a location inside the Activity branch from a
  /// route outside the shell — is the shape D2 actually punished.
  static const calendarNew = '$calendar/new';

  /// Query parameter seeding [calendarNew] with a date, as `yyyy-MM-dd`.
  ///
  /// A plain calendar date, not an instant and not a locale-formatted string:
  /// the builder resolves it against the TARGET's timezone once a target is
  /// picked, and which target that is is not known yet at this point.
  static const calendarDateParam = 'date';

  static String calendarNewFor(DateTime day) => Uri(
    path: calendarNew,
    queryParameters: {
      calendarDateParam:
          '${day.year.toString().padLeft(4, '0')}-'
          '${day.month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}',
    },
  ).toString();

  /// Parse [calendarDateParam] back to a LOCAL-kind date.
  ///
  /// Local-kind on purpose: it feeds `showDatePicker` and the builder's own
  /// `_date`, both of which work in device-local dates. Returns null for a
  /// missing or malformed value, so a hand-typed link degrades to the ordinary
  /// empty builder rather than throwing.
  static DateTime? calendarDateFrom(String? raw) {
    if (raw == null) return null;
    final parts = raw.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  /// **The full-screen alarm.** Where a fired reminder lands — top-level and
  /// OUTSIDE the tab shell on purpose: a ringing alarm is not a tab, it covers
  /// the whole screen and every route off it goes back INTO the shell via
  /// `outcomeForItem`. Reached only through `NotificationRouter.openItem`, which
  /// is the one place a reminder tap or full-screen launch is routed.
  static const alarm = '/alarm';
  static const alarmItemParam = 'item';

  static String alarmForItem(String itemId) =>
      Uri(path: alarm, queryParameters: {alarmItemParam: itemId}).toString();

  /// **The social layer.** Friends belongs under the You pillar rather than as
  /// a separate pillar. Keeping it in that branch is also load-bearing for
  /// notification entry: `go('/you/friends')` builds You underneath Friends,
  /// so Back has a main-tab destination even when the app was opened directly
  /// from a friend-accept notification.
  static const friends = '/you/friends';

  static const friendRequests = '$friends/requests';
  static const userSearch = '$friends/search';
  static const blockedUsers = '$friends/blocked';
  /// **Your voice-note library** (32d): every voice note you send, newest 20.
  /// In You's branch, pushed from its tile.
  static const voiceNotes = '/you/voice-notes';
  static const planRequests = '$friends/plan-requests';
  static const newPlanRequest = '$planRequests/new';
  static const fulfillPlanRequest = '$planRequests/fulfill';

  static String fulfillPlanRequestFor(String requestId) =>
      '$fulfillPlanRequest/$requestId';

  /// Viewing ONE person's profile.
  ///
  /// `/u/:uid` rather than `/profile/:uid`, because [profile] is the *edit your
  /// own* form — making the read-only view of a stranger a child of it would
  /// say the two are the same screen, and Back from a stranger's profile would
  /// drop the user into their own edit form.
  ///
  /// Keyed by uid, not by username. A handle is renameable, so a link built
  /// from one goes stale the moment its owner changes it; the uid never moves.
  /// `u` is in `kReservedUsernames`, so no user can ever claim a handle that
  /// would collide if a vanity path is added later.
  static const userProfile = '/u';

  static String userProfileFor(String uid) => '$userProfile/$uid';

  /// **The Track pillar** (personal time-tracking). Top-level and pushed for now,
  /// reached through a TEMPORARY account-popup entry (the redesign's
  /// temporary-door strategy — DECISIONS.md "UI redesign — Hearth + Candidate
  /// A"). Since the S5 cutover it is the **Track pillar** — a branch of the
  /// five-pillar shell, no longer a pushed route.
  static const track = '/track';

  /// **The You pillar** (profile / friends / calendar / permissions / sign
  /// out / dev). The old account popup, promoted to the fifth
  /// bottom-bar pillar at the S5 cutover — a branch of the shell.
  static const you = '/you';

  /// **The Stats pillar** — a placeholder dashboard shell (S5). The real
  /// computations are ungreenlit and out of that slice, so it renders honestly
  /// empty. A branch of the shell.
  static const stats = '/stats';

  /// **The Plan pillar** — the delegation hub, and the FIRST bottom-bar pillar
  /// since the S5 cutover (a branch of the five-pillar shell; `/` redirects
  /// here). It hosts the keep-alive inner TabBar: My Schedule / Activity /
  /// Groups (DECISIONS.md → "UI redesign — S4" and "— S5").
  ///
  /// Its detail screens are SUB-ROUTES ([scheduleBuilder],
  /// `groups/:groupId`) so each pushes into the Plan branch's own stack and Back
  /// returns here. The sub-tab to show and the item to highlight are NOT encoded
  /// in the URL — they come from `planIntentProvider`, set by the call site
  /// right before `go(plan)`. go_router caches this branch page, so query-only
  /// changes were unreliable (the intermittent highlight/tab-switch bug on the
  /// S5 device pass); a Riverpod intent notifies deterministically instead.
  static const plan = '/plan';

  /// Elapsed and completed target-side plans. A Plan sub-route so Back returns
  /// to My Schedule and the bottom navigation remains present.
  static const history = '$plan/history';

  /// The planner's create flow — a Plan sub-route so it stacks over the shell.
  /// (Was `/activity/schedule-builder` before the S5 cutover.)
  static const scheduleBuilder = '$plan/schedule-builder';

  /// Voice-flow query params seeding [scheduleBuilder] (S6). The Plan voice flow
  /// picks the target first, parses the spoken details, and pushes the builder
  /// with these filled. All are optional; a missing/malformed one degrades to
  /// the ordinary empty builder rather than throwing.
  static const sbTargetParam = 'target';
  static const sbGroupParam = 'group';
  static const sbSelfParam = 'self';
  static const sbTitleParam = 'title';
  static const sbTimeParam = 'time'; // 'HH:mm'

  /// Build the seeded builder URL. Only the fields that were actually parsed are
  /// carried; the rest are omitted and stay unset in the form.
  static String scheduleBuilderVoice({
    required String targetUid,
    required bool isSelf,
    String? groupId,
    String? title,
    DateTime? date,
    TimeOfDay? time,
  }) => Uri(
    path: scheduleBuilder,
    queryParameters: _voiceParams(
      targetUid: targetUid,
      isSelf: isSelf,
      groupId: groupId,
      title: title,
      date: date,
      time: time,
    ),
  ).toString();

  static Map<String, String> _voiceParams({
    required String targetUid,
    required bool isSelf,
    String? groupId,
    String? title,
    DateTime? date,
    TimeOfDay? time,
  }) {
    final params = <String, String>{
      sbTargetParam: targetUid,
      sbSelfParam: isSelf ? '1' : '0',
    };
    if (groupId != null) params[sbGroupParam] = groupId;
    if (title != null && title.trim().isNotEmpty) params[sbTitleParam] = title;
    if (date != null) {
      params[calendarDateParam] =
          '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';
    }
    if (time != null) {
      params[sbTimeParam] =
          '${time.hour.toString().padLeft(2, '0')}:'
          '${time.minute.toString().padLeft(2, '0')}';
    }
    return params;
  }

  /// Parse [sbTimeParam] ('HH:mm') back to a [TimeOfDay]; null if absent/bad.
  static TimeOfDay? timeOfDayFrom(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    return TimeOfDay(hour: h, minute: m);
  }


  /// Debug-only. The route itself is registered only in debug builds — see the
  /// `if (kDebugMode)` guard below. In release this path resolves to nothing.
  static const devMenu = '/dev';

  /// The reminder fire-timing audit readout. Debug-only for the same reason
  /// [devMenu] is: it is an instrument, not a feature. The CSV it displays is
  /// still written in release builds — that is the point of measuring real use —
  /// and is pulled off the device with `adb` when there is no dev menu to open.
  static const reminderDiagnostics = '/dev/reminders';
}

/// The app's router. A single plain Provider (no family / autoDispose) since
/// there's only ever one router.
///
/// Auth gating lives in `redirect`: it re-runs whenever auth state changes
/// (via refreshListenable). The async profile check (does a profile exist?) is
/// handled inside HomeGate, not here, to keep redirect synchronous and simple.
final routerProvider = Provider<GoRouter>((ref) {
  final authRepository = ref.watch(authRepositoryProvider);

  // Rebuild routing whenever the Firebase auth state changes.
  //
  // go_router never disposes a `refreshListenable` — GoRouteInformationProvider
  // only calls `removeListener` on it (information_provider.dart:318) — so the
  // StreamSubscription inside it is ours to cancel. Without this, a rebuilt or
  // discarded provider would leave a live listener on `authStateChanges()`.
  //
  // Defensive, not a live bug: this provider is never invalidated and
  // `authRepositoryProvider` never rebuilds, so today the only dispose is app
  // teardown. It matters the moment a scoped container or a test overrides
  // either provider, and the leak has no symptom to catch it by later.
  final refresh = GoRouterRefreshStream(authRepository.authStateChanges());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    // A cold start FROM an alarm opens on the alarm itself — no home screen
    // flashes first (device report 2026-09-25).
    initialLocation: alarmLaunchLocation() ?? Routes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final loggedIn = FirebaseAuth.instance.currentUser != null;
      final atAuth = state.matchedLocation == Routes.auth;

      // An invite App Link (`/i/u/…`, `/i/g/…`; item 17) is not a screen: it
      // is parked for PendingInviteListener, which acts once the person is
      // past sign-in and setup. Unknown or malformed `/i/` paths just go home.
      if (state.uri.path.startsWith('/i/')) {
        final invite = InviteLink.parsePath(state.uri.path);
        if (invite != null) {
          // Deferred: redirect can run while providers are being read.
          Future.microtask(
            () => ref.read(pendingInviteProvider.notifier).set(invite),
          );
        }
        return loggedIn ? Routes.home : Routes.auth;
      }

      // Not signed in → force to the auth screen.
      if (!loggedIn && !atAuth) return Routes.auth;
      // Signed in but sitting on auth → send home.
      if (loggedIn && atAuth) return Routes.home;
      return null; // no redirect
    },
    routes: [
      // `/` is a pure redirect: the shell's first branch IS the landing screen,
      // so home is an alias for it rather than a fourth screen. Keeping the path
      // registered means `redirect` (and any saved `/` link) still resolves.
      GoRoute(path: Routes.home, redirect: (context, state) => Routes.plan),
      GoRoute(
        path: Routes.auth,
        builder: (context, state) => const AuthScreen(),
      ),
      // The five-PILLAR home (S5 cutover). Each pillar is a BRANCH with its own
      // navigator, so a screen is registered exactly once and anything pushed
      // inside a branch keeps the bottom bar beneath it. The bar names the app's
      // pillars — Plan · Track · ⊕voice · Stats · You — where the ⊕ voice FAB is
      // NOT a branch but a docked FAB on `HomeShell` (§6.12). The three old
      // delegation stances (Groups / My Schedule / Activity) are now the
      // keep-alive sub-tabs INSIDE Plan (`PlanShell`), not branches here.
      //
      // Each branch's detail screens are SUB-ROUTES, so they resolve into the
      // branch's own navigator: the bar stays, Back returns to the pillar, and
      // every branch keeps its own stack. The Plan sub-tabs are a `TabController`
      // rather than routes, so two query params deep-link into them (`?tab=`,
      // `?item=`) — see the `Routes.plan` doc.
      //
      // HomeGate wraps the shell rather than gating in `redirect` — see the
      // synchronous-redirect note above and HomeGate's own doc comment.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeGate(child: HomeShell(navigationShell: navigationShell)),
        branches: [
          // Pillar 0 — Plan (the landing pillar; `/` redirects here).
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.plan,
                // The sub-tab + highlight come from `planIntentProvider` (set by
                // the call site before `go`), not query params — go_router caches
                // this branch page, so query-only changes were unreliable.
                builder: (context, state) => const PlanShell(),
                routes: [
                  GoRoute(
                    path: 'schedule-builder',
                    // Voice-flow seeds (S6) ride in as query params on the pushed
                    // URL. This is a PUSHED sub-route (rebuilt each push), not the
                    // cached branch root, so query params are reliable here — the
                    // reason `planIntentProvider` exists for `/plan` does not apply.
                    builder: (context, state) {
                      final q = state.uri.queryParameters;
                      final target = q[Routes.sbTargetParam];
                      if (target == null) return const ScheduleBuilderScreen();
                      return ScheduleBuilderScreen(
                        initialTargetUid: target,
                        initialGroupId: q[Routes.sbGroupParam],
                        initialIsSelf: q[Routes.sbSelfParam] == '1',
                        initialTitle: q[Routes.sbTitleParam],
                        initialDate: Routes.calendarDateFrom(
                          q[Routes.calendarDateParam],
                        ),
                        initialTime: Routes.timeOfDayFrom(
                          q[Routes.sbTimeParam],
                        ),
                      );
                    },
                  ),
                  GoRoute(
                    path: 'history',
                    builder: (context, state) => const HistoryScreen(),
                  ),
                  GoRoute(
                    path: 'groups/:groupId',
                    builder: (context, state) => GroupDetailScreen(
                      groupId: state.pathParameters['groupId']!,
                    ),
                    routes: [
                      GoRoute(
                        path: 'progress',
                        builder: (context, state) => GroupProgressScreen(
                          groupId: state.pathParameters['groupId']!,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          // Pillar 1 — Track.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.track,
                builder: (context, state) => const TrackScreen(),
              ),
            ],
          ),
          // Pillar 2 — Stats (placeholder shell; computations ungreenlit).
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.stats,
                builder: (context, state) => const StatsScreen(),
              ),
            ],
          ),
          // Pillar 3 — You.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.you,
                builder: (context, state) => const YouScreen(),
                routes: [
                  // The voice-note library (32d), pushed from its You tile.
                  GoRoute(
                    path: 'voice-notes',
                    builder: (context, state) => const VoiceLibraryScreen(),
                  ),
                  // Social screens live in You's branch. In particular, a
                  // friend-accept notification uses `go(Routes.friends)`; this
                  // parent route gives that deep link a real screen beneath it
                  // instead of leaving Friends as the root and letting Back
                  // exit the activity.
                  GoRoute(
                    path: 'friends',
                    builder: (context, state) => const FriendsScreen(),
                    routes: [
                      GoRoute(
                        path: 'requests',
                        builder: (context, state) =>
                            const FriendRequestsScreen(),
                      ),
                      GoRoute(
                        path: 'search',
                        builder: (context, state) => const UserSearchScreen(),
                      ),
                      GoRoute(
                        path: 'blocked',
                        builder: (context, state) => const BlockedUsersScreen(),
                      ),
                      GoRoute(
                        path: 'plan-requests',
                        builder: (context, state) => const PlanRequestsScreen(),
                        routes: [
                          GoRoute(
                            path: 'new',
                            builder: (context, state) =>
                                const CreatePlanRequestScreen(),
                          ),
                          GoRoute(
                            path: 'fulfill/:requestId',
                            builder: (context, state) =>
                                FulfillPlanRequestScreen(
                                  requestId: state.pathParameters['requestId']!,
                                ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      // Account-level, deliberately NOT nested: both are opened from the
      // account menu, which every tab shows, so neither belongs to one branch.
      // Pushed on the root navigator, they cover the bar and return to
      // whichever tab launched them.
      GoRoute(
        path: Routes.profile,
        builder: (context, state) => const ProfileEditScreen(),
      ),
      // One shared Archived view for both roles, reached from the account menu
      // rather than a per-tab control — a user archives items, not
      // items-as-target and items-as-planner.
      GoRoute(
        path: Routes.archived,
        builder: (context, state) => const ArchivedScreen(),
      ),
      // Permissions onboarding as a re-runnable destination. Same screen the
      // first-run gate shows inline; here it is pushed and its finish pops back
      // to whichever tab launched it.
      GoRoute(
        path: Routes.permissions,
        builder: (context, state) => OnboardingScreen(
          onFinished: () {
            if (context.canPop()) context.pop();
          },
        ),
      ),
      // The complete "How this app works" guide. Account-level and pushed,
      // alongside the other lens screens; see the doc on `Routes.howItWorks`.
      GoRoute(
        path: Routes.howItWorks,
        builder: (context, state) => const HowItWorksScreen(),
      ),
      // The full-screen alarm surface. Top-level and outside the shell so it
      // covers the nav bar the way a clock alarm covers everything; its Dismiss
      // routes back into the shell. Reached only from a fired reminder.
      GoRoute(
        path: Routes.alarm,
        builder: (context, state) => AlarmScreen(
          itemId: state.uri.queryParameters[Routes.alarmItemParam] ?? '',
        ),
      ),
      // The calendar. Root-pushed from My Schedule; its create flow is a
      // sub-route, so Back from the builder returns to the grid the user tapped.
      GoRoute(
        path: Routes.calendar,
        builder: (context, state) => const CalendarScreen(),
        routes: [
          GoRoute(
            path: 'new',
            builder: (context, state) => ScheduleBuilderScreen(
              initialDate: Routes.calendarDateFrom(
                state.uri.queryParameters[Routes.calendarDateParam],
              ),
            ),
          ),
        ],
      ),
      // One person's profile. Top-level so it can be pushed from anywhere a
      // person is named — a group roster, a friends list, a search result — and
      // return to where it was opened from.
      GoRoute(
        path: '${Routes.userProfile}/:uid',
        builder: (context, state) =>
            UserProfileScreen(uid: state.pathParameters['uid']!),
      ),
      // Dev scaffolding, registered ONLY in debug builds.
      //
      // The menu item that pushes this is already behind `kDebugMode` in
      // AccountButton, and no deep link reaches it (the manifest declares only
      // MAIN/LAUNCHER). But that guard sits in another file: one future
      // `context.push(Routes.devMenu)` written without it would make a dev
      // screen live in production. Guarding the route keeps the invariant
      // where the route is.
      //
      // `kDebugMode` is a compile-time constant, so in release this branch is
      // eliminated and `DevMenuScreen` becomes unreferenced — it is dropped
      // from the binary rather than merely being unreachable inside it.
      if (kDebugMode)
        GoRoute(
          path: Routes.devMenu,
          builder: (context, state) => const DevMenuScreen(),
          routes: [
            GoRoute(
              path: 'reminders',
              builder: (context, state) => const ReminderDiagnosticsScreen(),
            ),
          ],
        ),
    ],
  );
});

/// The alarm location a cold start was launched for, or null for an ordinary
/// launch. Native `MainActivity.getInitialRoute` puts `/alarm?item=<id>` there
/// when the full-screen alarm starts the process; Flutter exposes it
/// synchronously as `defaultRouteName`, before the first frame.
String? alarmLaunchLocation([String? defaultRouteName]) {
  final route =
      defaultRouteName ??
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;
  final uri = Uri.tryParse(route);
  if (uri == null || uri.path != Routes.alarm) return null;
  final item = uri.queryParameters[Routes.alarmItemParam];
  if (item == null || item.isEmpty) return null;
  return Routes.alarmForItem(item);
}
