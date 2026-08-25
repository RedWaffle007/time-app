import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../dev/dev_menu_screen.dart';
import '../features/approvals/presentation/pending_approvals_screen.dart';
import '../features/archive/presentation/archived_screen.dart';
import '../features/auth/application/auth_providers.dart';
import '../features/auth/presentation/auth_screen.dart';
import '../features/groups/presentation/group_detail_screen.dart';
import '../features/groups/presentation/groups_screen.dart';
import '../features/auth/presentation/profile_edit_screen.dart';
import '../features/chatbot/presentation/chat_gate.dart';
import '../features/chatbot/presentation/chatbot_settings_screen.dart';
import '../features/chatbot/presentation/model_setup_screen.dart';
import '../features/calendar/presentation/calendar_screen.dart';
import '../features/home/presentation/home_gate.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/social/presentation/blocked_users_screen.dart';
import '../features/social/presentation/friend_requests_screen.dart';
import '../features/social/presentation/friends_screen.dart';
import '../features/social/presentation/user_profile_screen.dart';
import '../features/social/presentation/user_search_screen.dart';
import '../features/home/presentation/home_shell.dart';
import '../features/outcomes/presentation/outcome_screen.dart';
import '../features/reminders/presentation/alarm_screen.dart';
import '../features/reminders/presentation/reminder_diagnostics_screen.dart';
import '../features/scheduling/presentation/planner_activity_screen.dart';
import '../features/scheduling/presentation/schedule_builder_screen.dart';
import '../features/home/presentation/you_screen.dart';
import '../features/plan/presentation/plan_shell.dart';
import '../features/time_tracking/presentation/track_screen.dart';
import 'go_router_refresh_stream.dart';

/// Central list of route paths/names, so screens don't hardcode strings.
///
/// The three tab roots are `/groups`, `/outcome` and `/activity`. A route that
/// belongs *to* a tab is nested under that tab's path, so its location names
/// the branch it lives in — `go()` from a notification therefore lands inside
/// the right tab with the nav bar and a back stack, not on a bare screen.
/// Account-level routes (`/profile`, `/archived`, `/dev`) stay top-level: they
/// are reached from the account menu on any tab and belong to no tab.
class Routes {
  static const home = '/'; // HomeGate: profile-completion or app home.
  static const auth = '/auth';
  static const profile = '/profile';
  static const groups = '/groups';
  static const outcome = '/outcome';
  static const plannerActivity = '/activity';
  // Nested under the tab each one belongs to (see the class doc).
  static const scheduleBuilder = '$plannerActivity/schedule-builder';
  static const approvals = '$outcome/approvals';
  static const archived = '/archived';

  /// **Permissions onboarding**, re-runnable from the account menu. Top-level
  /// and pushed, like [profile] and [archived] — it belongs to no tab. The
  /// first-run flow reaches the same screen inline through `OnboardingGate`;
  /// this route is the "review / fix my permissions" door after that.
  static const permissions = '/permissions';

  /// **The calendar** — a month/week/day view over the items that already
  /// exist. Top-level and pushed, reached from the account menu, for exactly
  /// the reason [archived] is: it merges the items you are the TARGET of with
  /// the ones you planned for others, so it belongs to no single tab. It is
  /// deliberately not a fourth nav destination — the bar's three tabs are the
  /// three stances in the delegation loop, and a calendar is a lens over all
  /// three rather than a fourth one (DECISIONS.md → "In-app calendar").
  static const calendar = '/calendar';

  /// Planning an item from a tapped date.
  ///
  /// This is the REAL [ScheduleBuilderScreen], not a parallel create flow — the
  /// calendar's whole integration with the builder is one optional
  /// `initialDate`. It is a sub-route of [calendar] for the same reason
  /// `/friends/search` is a sub-route of `/friends`: the calendar is pushed at
  /// the root, so its create flow belongs to its own stack and Back returns to
  /// the grid.
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
          calendarDateParam: '${day.year.toString().padLeft(4, '0')}-'
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

  /// Query parameter naming ONE item on [outcome], so a tapped reminder can
  /// single out the card it belongs to.
  ///
  /// A query parameter rather than a `/outcome/item/:id` sub-route on purpose:
  /// the destination is the same screen with the same list and the same Done /
  /// Skip controls, just scrolled and marked. A sub-route would be a second
  /// rendering of one item to keep in step with the first, and Back would drop
  /// the user onto the list they were already looking at.
  static const outcomeItemParam = 'item';

  static String outcomeForItem(String itemId) => Uri(
        path: outcome,
        queryParameters: {outcomeItemParam: itemId},
      ).toString();

  /// **The full-screen alarm.** Where a fired reminder lands — top-level and
  /// OUTSIDE the tab shell on purpose: a ringing alarm is not a tab, it covers
  /// the whole screen and every route off it goes back INTO the shell via
  /// `outcomeForItem`. Reached only through `NotificationRouter.openItem`, which
  /// is the one place a reminder tap or full-screen launch is routed.
  static const alarm = '/alarm';
  static const alarmItemParam = 'item';

  static String alarmForItem(String itemId) => Uri(
        path: alarm,
        queryParameters: {alarmItemParam: itemId},
      ).toString();

  /// **The social layer.** All top-level and pushed, deliberately — the same
  /// reasoning as [profile] and [archived]. The nav bar's three tabs are the
  /// three stances in the delegation loop (target, planner, group member) and a
  /// friend graph is none of them; making Friends a fourth tab would dilute
  /// that meaning exactly as `DECISIONS.md` 2026-08-18 records for the chatbot.
  ///
  /// They are reached from the account menu, which every tab's AppBar shows, so
  /// one entry point serves all three tabs and Back returns to whichever tab
  /// launched it.
  static const friends = '/friends';
  static const friendRequests = '$friends/requests';
  static const userSearch = '$friends/search';
  static const blockedUsers = '$friends/blocked';

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
  /// A"). It becomes a bottom-bar pillar at the S5 cutover; until then it lives
  /// beside the other account-menu destinations, covering the bar and returning
  /// to whichever tab launched it.
  static const track = '/track';

  /// **The You hub** (profile / friends / calendar / language practice /
  /// permissions / sign out / dev). The account popup promoted to a screen —
  /// top-level and pushed during migration, reached through a TEMPORARY
  /// account-popup entry. Becomes the fifth bottom-bar pillar at the S5 cutover
  /// (DECISIONS.md "UI redesign — Hearth + Candidate A").
  static const you = '/you';

  /// **The Plan shell** (redesign slice S4) — the delegation hub's inner-TabBar
  /// preview: My Schedule / Activity / Groups as swipeable, keep-alive sub-tabs.
  /// Top-level and pushed during migration, reached through a TEMPORARY
  /// account-popup entry ("Plan (preview)"), the same temporary-door strategy as
  /// [track] and [you]. It becomes the first bottom-bar pillar at the S5 cutover.
  ///
  /// Its detail screens are SUB-ROUTES (`schedule-builder`, `groups/:groupId`,
  /// `approvals`) so each pushes into the Plan shell's own stack and Back returns
  /// here — the `/calendar/new` precedent for a root-pushed screen whose create
  /// flows must not escape into a shell branch (see the `calendarNew` doc). They
  /// are second registrations of screens the old shell also registers; nothing
  /// deep-links to them, so the D2 ambiguity does not apply.
  static const plan = '/plan';

  /// The language-practice chatbot — a self-contained feature that shares the
  /// theme and this router with the delegation app and nothing else. Top-level,
  /// because it belongs to no tab and is not part of the core loop; reached from
  /// the account menu, alongside the other top-level routes above.
  static const chatbot = '/chatbot';
  static const chatbotSettings = '$chatbot/settings';

  /// Getting the on-device model onto this phone. A destination, **not** a gate
  /// in front of [chatbot] — the HTTP implementation still answers every
  /// message (DECISIONS.md, 2026-08-19).
  static const chatbotModel = '$chatbot/model';

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
    initialLocation: Routes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final loggedIn = FirebaseAuth.instance.currentUser != null;
      final atAuth = state.matchedLocation == Routes.auth;

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
      GoRoute(
        path: Routes.home,
        redirect: (context, state) => Routes.groups,
      ),
      GoRoute(
        path: Routes.auth,
        builder: (context, state) => const AuthScreen(),
      ),
      // The tabbed home. Each tab is a BRANCH with its own navigator, so a
      // screen is registered exactly once (D2 was the same three screens being
      // registered twice — as tabs here and as flat top-level paths below) and
      // anything pushed inside a branch keeps the NavigationBar beneath it.
      //
      // Each tab's detail screens are SUB-ROUTES of that tab, so they resolve
      // into the branch's own navigator: the bar stays, Back returns to the
      // tab, and every branch keeps its own stack. Sub-route paths are relative
      // (go_router forbids a leading `/` below the root), so the full location
      // is the tab path plus the segment — which is what the `Routes` constants
      // spell out.
      //
      // HomeGate wraps the shell rather than gating in `redirect` — see the
      // synchronous-redirect note above and HomeGate's own doc comment.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeGate(child: HomeShell(navigationShell: navigationShell)),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.groups,
                builder: (context, state) => const GroupsScreen(),
                routes: [
                  GoRoute(
                    path: ':groupId',
                    builder: (context, state) => GroupDetailScreen(
                      groupId: state.pathParameters['groupId']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.outcome,
                builder: (context, state) => OutcomeScreen(
                  highlightItemId:
                      state.uri.queryParameters[Routes.outcomeItemParam],
                ),
                routes: [
                  // The target's inbox belongs to My Schedule: the AppBar
                  // shortcut and the `created`/`withdrawn` notifications both
                  // land here, and Back drops to the tab either way.
                  GoRoute(
                    path: 'approvals',
                    builder: (context, state) => const PendingApprovalsScreen(),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.plannerActivity,
                builder: (context, state) => const PlannerActivityScreen(),
                routes: [
                  // Reached from Activity's FAB; planning an item is the
                  // planner's own flow, so it stacks over the planner tab.
                  GoRoute(
                    path: 'schedule-builder',
                    builder: (context, state) => const ScheduleBuilderScreen(),
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
      // The full-screen alarm surface. Top-level and outside the shell so it
      // covers the nav bar the way a clock alarm covers everything; its Dismiss
      // routes back into the shell. Reached only from a fired reminder.
      GoRoute(
        path: Routes.alarm,
        builder: (context, state) => AlarmScreen(
          itemId: state.uri.queryParameters[Routes.alarmItemParam] ?? '',
        ),
      ),
      // The calendar. Account-level and pushed, alongside Archived and for the
      // same reason — see the doc on `Routes.calendar`. Its create flow is a
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
      // The Track pillar, pushed at the root during the redesign migration. It
      // will move into the bottom bar at S5; a top-level pushed route now keeps
      // it reachable behind the temporary account-popup door with no bar change.
      GoRoute(
        path: Routes.track,
        builder: (context, state) => const TrackScreen(),
      ),
      // The You hub, pushed at the root during migration (S3). Moves into the
      // bottom bar at S5; a top-level pushed route keeps it reachable behind the
      // temporary account-popup door with no bar change.
      GoRoute(
        path: Routes.you,
        builder: (context, state) => const YouScreen(),
      ),
      // The Plan shell (S4), pushed at the root behind the temporary door. Its
      // three sub-tabs' detail pushes are sub-routes here so they stack over the
      // shell and Back returns to it — see the `Routes.plan` doc.
      GoRoute(
        path: Routes.plan,
        builder: (context, state) => const PlanShell(),
        routes: [
          GoRoute(
            path: 'schedule-builder',
            builder: (context, state) => const ScheduleBuilderScreen(),
          ),
          GoRoute(
            path: 'approvals',
            builder: (context, state) => const PendingApprovalsScreen(),
          ),
          GoRoute(
            path: 'groups/:groupId',
            builder: (context, state) => GroupDetailScreen(
              groupId: state.pathParameters['groupId']!,
            ),
          ),
        ],
      ),
      // The social layer. Account-level and pushed, for the reason spelled out
      // on the `Routes.friends` constant: a friend graph is not one of the
      // three stances the nav bar names.
      //
      // Search, requests and blocked users are SUB-ROUTES of `/friends`, so
      // each resolves into the same stack and Back returns to the friends list
      // rather than to whichever tab was underneath.
      GoRoute(
        path: Routes.friends,
        builder: (context, state) => const FriendsScreen(),
        routes: [
          GoRoute(
            path: 'requests',
            builder: (context, state) => const FriendRequestsScreen(),
          ),
          GoRoute(
            path: 'search',
            builder: (context, state) => const UserSearchScreen(),
          ),
          GoRoute(
            path: 'blocked',
            builder: (context, state) => const BlockedUsersScreen(),
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
      // The chatbot, kept out of the tab shell on purpose: it is not one of
      // the three roles the nav bar names, and nothing in the delegation loop
      // links to it. Reached from the account menu (`AccountButton`), which every
      // tab's AppBar shows — pushed, so it covers the bar and Back returns to
      // whichever tab launched it, exactly like `/profile` and `/archived`.
      // The dev menu still pushes it too, but is no longer the only way in
      // (DECISIONS.md, 2026-08-18).
      //
      // Registered in release too, unlike `/dev` — this is a real feature that
      // is merely unlaunched, not scaffolding. The settings screen is a
      // sub-route of it, so Back returns to the chat.
      GoRoute(
        path: Routes.chatbot,
        // The GATE, not the chat. Replies come from model files on this phone,
        // so the chat cannot open before they are here; the gate hands over to
        // it the moment they are (DECISIONS.md, 2026-08-19).
        builder: (context, state) => const ChatGate(),
        routes: [
          GoRoute(
            path: 'settings',
            builder: (context, state) => const ChatbotSettingsScreen(),
          ),
          // Downloading and verifying the on-device model. A sub-route for the
          // same reason `settings` is one: it belongs to the chatbot and Back
          // returns to the chat.
          //
          // It outlives `settings`. That screen is scoped to the HTTP
          // implementation and is deleted with it; this one is where the
          // feature is going.
          GoRoute(
            path: 'model',
            builder: (context, state) => const ModelSetupScreen(),
          ),
        ],
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
