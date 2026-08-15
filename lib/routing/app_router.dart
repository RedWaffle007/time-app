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
import '../features/home/presentation/home_gate.dart';
import '../features/home/presentation/home_shell.dart';
import '../features/outcomes/presentation/outcome_screen.dart';
import '../features/scheduling/presentation/planner_activity_screen.dart';
import '../features/scheduling/presentation/schedule_builder_screen.dart';
import 'go_router_refresh_stream.dart';

/// Central list of route paths/names, so screens don't hardcode strings.
class Routes {
  static const home = '/'; // HomeGate: profile-completion or app home.
  static const auth = '/auth';
  static const profile = '/profile';
  static const groups = '/groups';
  static const scheduleBuilder = '/schedule-builder';
  static const approvals = '/approvals';
  static const outcome = '/outcome';
  static const plannerActivity = '/activity';
  static const archived = '/archived';
  /// Debug-only. The route itself is registered only in debug builds — see the
  /// `if (kDebugMode)` guard below. In release this path resolves to nothing.
  static const devMenu = '/dev';
}

/// The app's router. A single plain Provider (no family / autoDispose) since
/// there's only ever one router.
///
/// Auth gating lives in `redirect`: it re-runs whenever auth state changes
/// (via refreshListenable). The async profile check (does a profile exist?) is
/// handled inside HomeGate, not here, to keep redirect synchronous and simple.
final routerProvider = Provider<GoRouter>((ref) {
  final authRepository = ref.watch(authRepositoryProvider);

  return GoRouter(
    initialLocation: Routes.home,
    // Rebuild routing whenever the Firebase auth state changes.
    refreshListenable: GoRouterRefreshStream(authRepository.authStateChanges()),
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
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.outcome,
                builder: (context, state) => const OutcomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.plannerActivity,
                builder: (context, state) => const PlannerActivityScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: Routes.profile,
        builder: (context, state) => const ProfileEditScreen(),
      ),
      GoRoute(
        path: '/groups/:groupId',
        builder: (context, state) =>
            GroupDetailScreen(groupId: state.pathParameters['groupId']!),
      ),
      GoRoute(
        path: Routes.scheduleBuilder,
        builder: (context, state) => const ScheduleBuilderScreen(),
      ),
      GoRoute(
        path: Routes.approvals,
        builder: (context, state) => const PendingApprovalsScreen(),
      ),
      // One shared Archived view for both roles, reached from the account menu
      // rather than a per-tab control — a user archives items, not
      // items-as-target and items-as-planner.
      GoRoute(
        path: Routes.archived,
        builder: (context, state) => const ArchivedScreen(),
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
        ),
    ],
  );
});
