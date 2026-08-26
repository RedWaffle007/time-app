import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/planner_access_repository.dart';
import '../domain/planner_grant.dart';
import 'group_providers.dart';

/// Keeps the caller's own `plannerAccess` hint rows in step with the grants THEY
/// hold, **off the grant stream** — never off grant transitions.
///
/// ## Why planner-side now
///
/// The hint row tells the schedule-read rule which group to re-verify the
/// caller's grant in (`callerHasPlannerAccess` in `firestore.rules`). The rule
/// checks the LIVE grant, so the row is not the permission — which is exactly
/// what lets the PLANNER write their own row. Running this off the grants the
/// caller holds removes the old dependency on the *target* being online to
/// provision access: the planner provisions it themselves, and can only ever
/// name a group a real grant backs (the rule rejects anything else).
///
/// ## The one design rule, and do not undo it
///
/// There is no hook in `setPlannerGrant()` or `revokeMyPlannerGrant()`. One rule
/// — *I should hold exactly one hint row per target I currently have a group
/// grant over, naming a live group* — is applied to whatever the stream says.
/// Grant, revoke, a grant in a second group, losing a group: none is a special
/// case. **Adding a hint write inside a grant transition is a regression.**
///
/// Idempotent, so it is safe to run on every emission and every app start; it
/// also backfills pre-existing grants on next open with no migration.
///
/// A stale row (grant revoked while the planner was offline) grants nothing —
/// the read re-checks the grant — so the delete below is cleanup, not the
/// security boundary.
class PlannerAccessReconciler {
  PlannerAccessReconciler(this._repository);

  final PlannerAccessRepository _repository;

  /// Guards against two reconciles interleaving — the stream can emit again
  /// while the first pass is still awaiting its writes.
  bool _running = false;

  /// Make the caller's hint rows match [grants] for planner [plannerUid].
  ///
  /// Returns the target ids it added and removed, so a test can assert the diff.
  Future<({Set<String> added, Set<String> removed})> reconcile({
    required String plannerUid,
    required List<PlannerGrant> grants,
  }) async {
    if (_running) return (added: <String>{}, removed: <String>{});
    _running = true;
    try {
      final desired = desiredAccess(plannerUid: plannerUid, grants: grants);
      final current = await _repository.targetsFor(plannerUid);

      final added = desired.keys.toSet().difference(current);
      final removed = current.difference(desired.keys.toSet());

      // Removals first, symmetry with the old pass: a half-failed run leaves
      // "a hint I meant to add hasn't arrived" rather than a dangling row (which
      // is inert anyway).
      for (final target in removed) {
        await _repository.revoke(plannerUid: plannerUid, targetUid: target);
      }
      // Write every desired row (idempotent), so a row whose group was revoked
      // but who still has another live grant is refreshed to the live group.
      for (final entry in desired.entries) {
        await _repository.grant(
          plannerUid: plannerUid,
          targetUid: entry.key,
          groupId: entry.value,
        );
      }
      return (added: added, removed: removed);
    } finally {
      _running = false;
    }
  }

  /// The rule, isolated so it can be tested without a repository: for each
  /// target the caller has a LIVE GROUP grant over, one live groupId.
  ///
  /// Skips self-grants (a target reads their own schedule already) and grants
  /// with an EMPTY group — those are friendship-scoped grants, which authorize
  /// reads directly via a computed pair id and need no hint row.
  static Map<String, String> desiredAccess({
    required String plannerUid,
    required List<PlannerGrant> grants,
  }) {
    final byTarget = <String, String>{};
    for (final grant in grants) {
      if (grant.granted &&
          grant.plannerUid == plannerUid &&
          grant.targetUid.isNotEmpty &&
          grant.targetUid != plannerUid &&
          grant.groupId.isNotEmpty) {
        // First live group wins; any live grant proves access equally.
        byTarget.putIfAbsent(grant.targetUid, () => grant.groupId);
      }
    }
    return byTarget;
  }
}

final plannerAccessRepositoryProvider =
    Provider<PlannerAccessRepository>((ref) {
  return PlannerAccessRepository(FirebaseFirestore.instance);
});

final plannerAccessReconcilerProvider =
    Provider<PlannerAccessReconciler>((ref) {
  return PlannerAccessReconciler(ref.watch(plannerAccessRepositoryProvider));
});

/// Runs the reconcile on every emission of [myPlanningTargetsProvider] — the
/// grants the signed-in user HOLDS (the same stream the builder's target picker
/// reads), so the hint rows track exactly what the planner can currently plan.
///
/// A `listen`, not a widget: the rows must be maintained whether or not any
/// planning screen is mounted.
final plannerAccessSyncProvider = Provider<void>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return;
  final reconciler = ref.watch(plannerAccessReconcilerProvider);

  ref.listen<AsyncValue<List<PlannerGrant>>>(
    myPlanningTargetsProvider,
    (_, next) {
      final grants = next.value;
      if (grants == null) return;
      // Best-effort: a failed reconcile leaves the previous rows in place and
      // the next emission retries. Never surfaced as a UI error.
      unawaited(reconciler
          .reconcile(plannerUid: uid, grants: grants)
          .catchError((_) => (added: <String>{}, removed: <String>{})));
    },
    fireImmediately: true,
  );
});
