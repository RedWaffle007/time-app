import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../groups/application/group_providers.dart';
import '../../groups/domain/planner_grant.dart';
import '../data/avatar_uploader.dart';
import '../data/block_repository.dart';
import '../data/friend_repository.dart';
import '../data/planning_permission_repository.dart';
import '../data/profile_stats_repository.dart';
import '../data/username_repository.dart';
import '../data/worker_avatar_uploader.dart';
import '../domain/friend_request.dart';
import '../domain/friendship.dart';
import '../domain/planning_request.dart';
import '../domain/profile_visibility.dart';
import '../domain/user_block.dart';

// ---------------------------------------------------------------------------
// Repositories — plain providers, created once, exactly as the rest of the app
// does it (`schedule_providers.dart`, `archive_providers.dart`).
// ---------------------------------------------------------------------------

final usernameRepositoryProvider = Provider<UsernameRepository>((ref) {
  return UsernameRepository(FirebaseFirestore.instance);
});

final friendRepositoryProvider = Provider<FriendRepository>((ref) {
  return FriendRepository(FirebaseFirestore.instance);
});

final blockRepositoryProvider = Provider<BlockRepository>((ref) {
  return BlockRepository(FirebaseFirestore.instance);
});

final profileStatsRepositoryProvider = Provider<ProfileStatsRepository>((ref) {
  return ProfileStatsRepository(FirebaseFirestore.instance);
});

/// **The one line that changes when storage changes.**
///
/// Same role as `chatbotServiceProvider`: everything above this depends on the
/// [AvatarUploader] interface, so moving from the Worker+Supabase path to
/// Firebase Storage (on card-day) or to a self-hosted bucket is this line and
/// nothing else. See `worker_avatar_uploader.dart` for why the current
/// implementation goes through the Worker rather than uploading directly.
final avatarUploaderProvider = Provider<AvatarUploader>((ref) {
  return const WorkerAvatarUploader();
});

// ---------------------------------------------------------------------------
// The signed-in user's own social graph.
// ---------------------------------------------------------------------------

/// Everyone the signed-in user is friends with.
final myFriendshipsProvider = StreamProvider<List<Friendship>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(friendRepositoryProvider).watchFriends(uid);
});

/// Just the uids, which is what most callers actually want.
final myFriendUidsProvider = Provider<AsyncValue<List<String>>>((ref) {
  final uid = ref.watch(currentUidProvider);
  return ref.watch(myFriendshipsProvider).whenData(
        (friendships) =>
            [for (final f in friendships) f.otherUid(uid ?? '')],
      );
});

/// How many friends the signed-in user has.
///
/// Derived from the list already streaming, **not** a denormalised counter on
/// the profile and not a `count()` aggregate. A stored counter cannot be
/// maintained correctly without a server: accepting a request and incrementing
/// two counters is three writes across two users' documents, no client may
/// write another user's profile, and any client that could would race. The list
/// is already in memory for the friends screen, so its length is free and
/// cannot drift from it.
///
/// The cost, stated: this is the *viewer's own* count only. A visitor's device
/// cannot enumerate someone else's friendships (the rules scope every read to
/// the caller), so another person's friend count is not shown at all rather
/// than shown wrong — see [friendCountForProvider].
final myFriendCountProvider = Provider<AsyncValue<int>>((ref) {
  return ref.watch(myFriendshipsProvider).whenData((f) => f.length);
});

/// Friend requests waiting on the signed-in user to decide.
final incomingRequestsProvider = StreamProvider<List<FriendRequest>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(friendRepositoryProvider).watchIncomingRequests(uid);
});

/// Requests the signed-in user has sent and nobody has answered.
final outgoingRequestsProvider = StreamProvider<List<FriendRequest>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(friendRepositoryProvider).watchOutgoingRequests(uid);
});

/// How many requests are waiting on the user. Drives the badge on the Friends
/// entry, in the same shape as the pending-items badge on the nav bar: it reads
/// zero on loading or error, because a badge is an invitation to act and must
/// never invent one. Counts BOTH friend requests and planning-permission
/// requests — both live on the Requests screen and both wait on the user.
final incomingRequestCountProvider = Provider<int>((ref) {
  final friends = ref.watch(incomingRequestsProvider).maybeWhen(
        data: (requests) => requests.length,
        orElse: () => 0,
      );
  final planning = ref.watch(incomingPlanningRequestsProvider).maybeWhen(
        data: (requests) => requests.length,
        orElse: () => 0,
      );
  return friends + planning;
});

/// Everyone the signed-in user has blocked.
final myBlocksProvider = StreamProvider<List<UserBlock>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(blockRepositoryProvider).watchMyBlocks(uid);
});

// ---------------------------------------------------------------------------
// Relationship with ONE other user — what a profile screen needs.
// ---------------------------------------------------------------------------

/// Whether a block exists in either direction between the signed-in user and
/// [otherUid].
final blockPairProvider =
    StreamProvider.family<({bool iBlocked, bool theyBlocked}), String>(
        (ref, otherUid) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null || uid == otherUid) {
    return Stream.value((iBlocked: false, theyBlocked: false));
  }
  return ref
      .watch(blockRepositoryProvider)
      .watchBlockPair(viewerUid: uid, otherUid: otherUid);
});

/// Whether the signed-in user and [otherUid] are friends.
///
/// **Derived from the caller-scoped [myFriendshipsProvider] query, NOT a
/// per-pair `friendships/{id}` doc listener.** A single-doc listener on a
/// computed id that does not exist yet is denied (the rule dereferences a null
/// `resource`) and, being a Firestore listener, TERMINATES on that error — so it
/// never observes the friendship formed afterwards, and a profile button stays
/// stale. The `participants array-contains me` query never hits that denial and
/// stays live, so accepting a request flips this the instant the friendship
/// lands. Same reasoning for the two request providers below. See DECISIONS.md
/// "Friend-request reactivity + lifecycle (2026-08-24)".
final isFriendProvider = Provider.family<AsyncValue<bool>, String>((ref, otherUid) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null || uid == otherUid) return const AsyncData(false);
  return ref
      .watch(myFriendUidsProvider)
      .whenData((uids) => uids.contains(otherUid));
});

/// The signed-in user's PENDING outgoing request to [otherUid], if any.
/// Derived from [outgoingRequestsProvider] (a live, caller-scoped query) so the
/// button reflects a just-sent request immediately — see [isFriendProvider].
final outgoingRequestToProvider =
    Provider.family<AsyncValue<FriendRequest?>, String>((ref, otherUid) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null || uid == otherUid) return const AsyncData(null);
  return ref.watch(outgoingRequestsProvider).whenData((requests) {
    for (final r in requests) {
      if (r.toUid == otherUid) return r;
    }
    return null;
  });
});

/// [otherUid]'s PENDING request to the signed-in user, if any. Derived from
/// [incomingRequestsProvider] — see [isFriendProvider].
final incomingRequestFromProvider =
    Provider.family<AsyncValue<FriendRequest?>, String>((ref, otherUid) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null || uid == otherUid) return const AsyncData(null);
  return ref.watch(incomingRequestsProvider).whenData((requests) {
    for (final r in requests) {
      if (r.fromUid == otherUid) return r;
    }
    return null;
  });
});

/// **The profile screen's single source of truth for what to render.**
///
/// Combines five live facts into the one pure decision in
/// `profile_visibility.dart`. Every one of them is a listener that can change
/// while the screen is open — the other person accepting, or blocking — so this
/// is a derived provider rather than a one-shot read.
///
/// It resolves to a value as soon as the pieces are known, and while they are
/// not it stays [AsyncLoading]. **It never degrades to a permissive default.**
/// If the block state is unknown, the honest answer is "still loading", not
/// "not blocked" — the latter would flash a profile open for a moment before
/// closing it again, which is exactly the leak the block exists to prevent.
final profileVisibilityProvider =
    Provider.family<AsyncValue<ProfileVisibility>, String>((ref, profileUid) {
  final viewerUid = ref.watch(currentUidProvider);
  if (viewerUid == null) return const AsyncLoading();

  if (viewerUid == profileUid) {
    return AsyncData(
      visibilityFor(relation: ProfileRelation.self, isPublic: true),
    );
  }

  final blocks = ref.watch(blockPairProvider(profileUid));
  final friend = ref.watch(isFriendProvider(profileUid));
  final outgoing = ref.watch(outgoingRequestToProvider(profileUid));
  final incoming = ref.watch(incomingRequestFromProvider(profileUid));
  final profile = ref.watch(profileByUidProvider(profileUid));

  // Any genuine error surfaces — a profile that cannot establish the
  // relationship must say so rather than guess at one.
  for (final async in [blocks, friend, outgoing, incoming, profile]) {
    if (async.hasError) {
      return AsyncError(async.error!, async.stackTrace ?? StackTrace.empty);
    }
  }

  final blockState = blocks.value;
  final isFriend = friend.value;
  if (blockState == null || isFriend == null) return const AsyncLoading();

  final relation = relationBetween(
    viewerUid: viewerUid,
    profileUid: profileUid,
    isFriend: isFriend,
    viewerBlockedThem: blockState.iBlocked,
    theyBlockedViewer: blockState.theyBlocked,
    outgoingRequestPending: outgoing.value?.isPending ?? false,
    incomingRequestPending: incoming.value?.isPending ?? false,
  );

  return AsyncData(
    visibilityFor(
      relation: relation,
      // A profile that has not loaded is treated as PRIVATE. Failing closed
      // matters here: the opposite default would show a private user's numbers
      // for the frame before their profile arrived.
      isPublic: profile.value?.isPublic ?? false,
    ),
  );
});

/// Another user's friend count, which is deliberately **not available**.
///
/// Kept as a named provider rather than simply omitted, so the next person to
/// look for it finds the reason instead of adding a query that will be denied.
/// The rules scope every friendship read to the caller (`participants`
/// array-contains the caller), so a visitor's device cannot enumerate someone
/// else's friendships — by design, since the alternative is letting anyone map
/// the entire social graph.
///
/// Publishing a count into `profileStats` would be the way to offer it. That is
/// a deliberate disclosure decision, not a technical gap, and it has not been
/// made — so nothing renders it.
final friendCountForProvider = Provider.family<int?, String>((ref, uid) {
  final me = ref.watch(currentUidProvider);
  if (me != null && me == uid) return ref.watch(myFriendCountProvider).value;
  return null;
});

// ---------------------------------------------------------------------------
// Friendship-scoped planning permission (#4). The grant is target-controlled;
// the request flow lets a friend ask. See PlanningPermissionRepository.
// ---------------------------------------------------------------------------

final planningPermissionRepositoryProvider =
    Provider<PlanningPermissionRepository>((ref) {
  return PlanningPermissionRepository(FirebaseFirestore.instance);
});

/// Whether [friendUid] may currently plan for the signed-in user — the state of
/// the "Let them plan for me" toggle. Derived from the live `grantsOverMe`
/// collection-group query (not a per-doc listener, which would terminate on the
/// absence-denial), and scoped to the FRIENDSHIP grant (`groupId == ''`) so the
/// toggle reflects exactly what it writes — a coexisting group grant does not
/// make it read "on".
final canFriendPlanForMeProvider =
    Provider.family<AsyncValue<bool>, String>((ref, friendUid) {
  return ref.watch(grantsOverMeProvider).whenData((grants) => grants.any((g) =>
      g.plannerUid == friendUid && g.granted && g.groupId.isEmpty));
});

/// Whether the signed-in user may currently plan for [friendUid] via a
/// FRIENDSHIP grant — drives the "Ask to plan for them" control's resolved
/// state. From the live, granted-filtered `myPlanningTargets` query.
final iCanPlanForProvider =
    Provider.family<AsyncValue<bool>, String>((ref, friendUid) {
  return ref.watch(myPlanningTargetsProvider).whenData((grants) => grants.any(
      (g) => g.targetUid == friendUid && g.granted && g.groupId.isEmpty));
});

/// My pending outgoing planning requests, live (caller-scoped `fromUid == me`).
final myOutgoingPlanningRequestsProvider =
    StreamProvider<List<PlanningRequest>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref
      .watch(planningPermissionRepositoryProvider)
      .watchOutgoingRequests(uid);
});

/// The normal-kind planning request the signed-in user has sent to [friendUid],
/// if one is pending — derived from the live outgoing query so a just-sent
/// request shows immediately.
final outgoingPlanningRequestProvider =
    Provider.family<AsyncValue<PlanningRequest?>, String>((ref, friendUid) {
  return ref.watch(myOutgoingPlanningRequestsProvider).whenData((requests) {
    for (final r in requests) {
      if (r.toUid == friendUid && r.kind == PlanningKind.normal) return r;
    }
    return null;
  });
});

/// Planning-permission requests waiting on the signed-in user to decide.
final incomingPlanningRequestsProvider =
    StreamProvider<List<PlanningRequest>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(planningPermissionRepositoryProvider).watchIncoming(uid);
});

// ---------------------------------------------------------------------------
// Emergency planning permission (#5). A SEPARATE grant (emergencyGrants) and a
// separate request kind — independent of the normal grant in every direction.
// ---------------------------------------------------------------------------

/// Emergency grants OTHER people hold over me — who may emergency-plan for me.
final emergencyGrantsOverMeProvider =
    StreamProvider<List<PlannerGrant>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref
      .watch(planningPermissionRepositoryProvider)
      .watchEmergencyGrantsOverTarget(uid);
});

/// Targets I may EMERGENCY-plan for (granted). Drives the builder's emergency
/// tier availability and the profile "I can emergency-plan for them" state.
final myEmergencyTargetsProvider = StreamProvider<List<PlannerGrant>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref
      .watch(planningPermissionRepositoryProvider)
      .watchEmergencyTargetsFor(uid);
});

/// Whether [friendUid] may currently EMERGENCY-plan for me — the "Let them set
/// emergency alarms for me" toggle state.
final canFriendEmergencyPlanForMeProvider =
    Provider.family<AsyncValue<bool>, String>((ref, friendUid) {
  return ref.watch(emergencyGrantsOverMeProvider).whenData((grants) =>
      grants.any((g) => g.plannerUid == friendUid && g.granted));
});

/// Whether I may currently EMERGENCY-plan for [friendUid].
final iCanEmergencyPlanForProvider =
    Provider.family<AsyncValue<bool>, String>((ref, friendUid) {
  return ref.watch(myEmergencyTargetsProvider).whenData(
      (grants) => grants.any((g) => g.targetUid == friendUid && g.granted));
});

/// My pending outgoing EMERGENCY request to [friendUid], if any.
final outgoingEmergencyRequestProvider =
    Provider.family<AsyncValue<PlanningRequest?>, String>((ref, friendUid) {
  return ref.watch(myOutgoingPlanningRequestsProvider).whenData((requests) {
    for (final r in requests) {
      if (r.toUid == friendUid && r.kind == PlanningKind.emergency) return r;
    }
    return null;
  });
});
