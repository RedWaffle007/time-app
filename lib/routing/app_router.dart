import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../dev/dev_menu_screen.dart';
import '../features/approvals/presentation/pending_approvals_screen.dart';
import '../features/auth/application/auth_providers.dart';
import '../features/auth/presentation/auth_screen.dart';
import '../features/groups/presentation/group_detail_screen.dart';
import '../features/groups/presentation/groups_screen.dart';
import '../features/auth/presentation/profile_edit_screen.dart';
import '../features/home/presentation/home_gate.dart';
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
  static const devMenu = '/dev'; // debug-only entry, reachable from AccountButton
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
      GoRoute(
        path: Routes.home,
        builder: (context, state) => const HomeGate(),
      ),
      GoRoute(
        path: Routes.auth,
        builder: (context, state) => const AuthScreen(),
      ),
      GoRoute(
        path: Routes.profile,
        builder: (context, state) => const ProfileEditScreen(),
      ),
      GoRoute(
        path: Routes.groups,
        builder: (context, state) => const GroupsScreen(),
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
      GoRoute(
        path: Routes.outcome,
        builder: (context, state) => const OutcomeScreen(),
      ),
      GoRoute(
        path: Routes.plannerActivity,
        builder: (context, state) => const PlannerActivityScreen(),
      ),
      GoRoute(
        path: Routes.devMenu,
        builder: (context, state) => const DevMenuScreen(),
      ),
    ],
  );
});
