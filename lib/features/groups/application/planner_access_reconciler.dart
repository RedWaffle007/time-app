import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/planner_access_repository.dart';
import '../domain/planner_grant.dart';
import 'group_providers.dart';

/// Keeps `plannerAccess` in step with `plannerGrants`, **off the grant stream**.
///
/// ## The one design rule, and do not undo it
///
/// There is no hook in `setPlannerGrant()` or `revokeMyPlannerGrant()`. One rule
/// — *the mirror should hold exactly the planners who currently have an active
/// grant over me* — is applied to whatever the stream currently says. Grant,
/// revoke, a grant in a second group, being ejected from a group: none of them
/// is a special case, because each simply changes what the stream emits.
///
/// **Adding a mirror write inside a grant transition is a regression**, not
/// belt-and-braces. It creates a second place that decides, and the two will
/// disagree. Here the argument is sharper than it is for reminders or stats: a
/// transition-driven mirror that half-fails on revoke leaves the planner able to
/// read the target's schedule *after* the target revoked. That is a security
/// staleness, not a missed notification.
///
/// It also solves backfill for nothing: grants that predate this feature get
/// their mirror the first time the target opens the app, with no migration.
///
/// ## What it cannot do
///
/// The mirror is client-maintained, so a revoke while the target is offline does
/// not reach it until they are next online. In practice the target revokes *in
/// the app*, so the write and this reconcile happen together — but the window is
/// real, and closing it needs a Cloud Function this project does not have.
class PlannerAccessReconciler {
  PlannerAccessReconciler(this._repository);

  final PlannerAccessRepository _repository;

  /// Guards against two reconciles interleaving — the stream can emit again
  /// while the first pass is still awaiting its writes, and the two would race
  /// on the same documents.
  bool _running = false;

  /// Make the mirror match [grants] for [targetUid].
  ///
  /// Idempotent, which is what makes it safe to run on every emission. Returns
  /// the ids it touched, so a test can assert the diff rather than the calls.
  Future<({Set<String> added, Set<String> removed})> reconcile({
    required String targetUid,
    required List<PlannerGrant> grants,
  }) async {
    if (_running) return (added: <String>{}, removed: <String>{});
    _running = true;
    try {
      final desired = desiredPlanners(targetUid: targetUid, grants: grants);
      final current = await _repository.plannersFor(targetUid);

      final added = desired.difference(current);
      final removed = current.difference(desired);

      // Removals first. If the pass dies half-way, the failure mode is "access
      // the target meant to give has not arrived yet" rather than "access the
      // target revoked is still live".
      for (final planner in removed) {
        await _repository.revoke(plannerUid: planner, targetUid: targetUid);
      }
      for (final planner in added) {
        await _repository.grant(plannerUid: planner, targetUid: targetUid);
      }
      return (added: added, removed: removed);
    } finally {
      _running = false;
    }
  }

  /// The rule, isolated so it can be tested without a repository.
  ///
  /// Deduped across groups on purpose: two grants in two groups are one access
  /// row, and revoking one of them must not remove it.
  static Set<String> desiredPlanners({
    required String targetUid,
    required List<PlannerGrant> grants,
  }) {
    return {
      for (final grant in grants)
        if (grant.granted &&
            grant.targetUid == targetUid &&
            grant.plannerUid.isNotEmpty &&
            // A self-grant would mirror the target to themselves. The rules
            // already let a target read their own schedule, so the row would be
            // dead weight that also reads as though it meant something.
            grant.plannerUid != targetUid)
          grant.plannerUid,
    };
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

/// Grants OTHER people hold over the signed-in user — the stream the mirror is
/// derived from. The rules already permit this read
/// (`resource.data.targetUid == request.auth.uid`).
final grantsOverMeProvider = StreamProvider<List<PlannerGrant>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(groupRepositoryProvider).watchGrantsOverTarget(uid);
});

/// Runs the reconcile on every emission of [grantsOverMeProvider].
///
/// A `listen`, not a widget: the mirror must be maintained whether or not any
/// screen showing grants is mounted.
final plannerAccessSyncProvider = Provider<void>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return;
  final reconciler = ref.watch(plannerAccessReconcilerProvider);

  ref.listen<AsyncValue<List<PlannerGrant>>>(
    grantsOverMeProvider,
    (_, next) {
      final grants = next.value;
      if (grants == null) return;
      // Best-effort: a failed reconcile leaves the previous mirror in place and
      // the next emission tries again. It must never surface as a UI error —
      // nobody asked for this to happen.
      unawaited(reconciler
          .reconcile(targetUid: uid, grants: grants)
          .catchError((_) => (added: <String>{}, removed: <String>{})));
    },
    fireImmediately: true,
  );
});
