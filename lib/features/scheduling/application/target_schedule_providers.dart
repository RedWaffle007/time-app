import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../groups/application/group_providers.dart';
import '../domain/schedule_item.dart';
import 'schedule_providers.dart';

/// **A target's live schedule, as seen by a planner.**
///
/// This is a `.snapshots()` stream all the way down, so the modal is live: if
/// the target books something while the planner has the modal open, the row
/// greys out under them. That is the first line of defence against a stale
/// view; the slot lock in `ScheduleRepository.createItem` is the one that
/// actually holds.
///
/// Reading this requires `plannerAccess/{me}_{targetUid}` to exist — see
/// `firestore.rules`. Without it the stream errors with `permission-denied`,
/// which is the correct failure: no grant, no schedule.
///
/// **The RECORD stream, not the filtered view.** `myItemsAsTargetProvider`
/// applies the viewer's own archive, and archiving is per-user — the planner's
/// archive says nothing about whether the target's half-hour is occupied.
/// Availability has to be computed from everything that is really there.
final targetScheduleProvider =
    StreamProvider.family<List<ScheduleItem>, String>((ref, targetUid) {
  return ref.watch(scheduleRepositoryProvider).watchItemsForTarget(targetUid);
});

/// Does the signed-in user currently hold a planner grant over [targetUid]?
///
/// Read from `plannerGrants` — the source of truth — never from the
/// `plannerAccess` mirror. The mirror exists so the RULES engine can answer this
/// without a query; the client can query, so it uses the real thing and cannot
/// be fooled by a stale row.
///
/// This gates whether the modal opens at all. No grant, no modal.
final canViewTargetScheduleProvider =
    Provider.family<bool, String>((ref, targetUid) {
  final grants = ref.watch(myPlanningTargetsProvider).value;
  if (grants == null) return false;
  return grants.any((g) => g.granted && g.targetUid == targetUid);
});
