import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../social/application/social_providers.dart';
import '../domain/schedule_item.dart';
import 'schedule_providers.dart';

/// **A target's live schedule, as seen by a planner.**
///
/// This is a `.snapshots()` stream all the way down, so the modal is live: if
/// the target books something while the planner has the modal open, the row
/// updates under them. Existing plans remain visible as context, but never
/// disable a time: schedule items are point alarms and carry no duration.
///
/// Group access requires `plannerAccess/{me}_{targetUid}`; friendship access is
/// authorized directly by the profile grant. Without the effective grant the
/// stream errors with `permission-denied`.
///
/// **The RECORD stream, not the filtered view.** `myItemsAsTargetProvider`
/// applies the viewer's own archive, and archiving is per-user — the planner's
/// archive says nothing about whether the target's half-hour is occupied.
/// Availability has to be computed from everything that is really there.
final targetScheduleProvider =
    StreamProvider.family<List<ScheduleItem>, String>((ref, targetUid) {
      return ref
          .watch(scheduleRepositoryProvider)
          .watchItemsForTarget(targetUid);
    });

/// Does the signed-in user currently hold a planner grant over [targetUid]?
///
/// Read from `plannerGrants` — the source of truth — never from the
/// `plannerAccess` mirror. The mirror exists so the RULES engine can answer this
/// without a query; the client can query, so it uses the real thing and cannot
/// be fooled by a stale row.
///
/// This gates whether the modal opens at all. No grant, no modal.
final canViewTargetScheduleProvider = Provider.family<bool, String>((
  ref,
  targetUid,
) {
  final grants = ref.watch(effectivePlanningTargetsProvider).value;
  if (grants == null) return false;
  return grants.any((g) => g.granted && g.targetUid == targetUid);
});
