import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/schedule_item.dart';
import 'schedule_providers.dart';

/// **A target's live schedule, projected only into conflict times by callers.**
///
/// This is a `.snapshots()` stream all the way down, so a day warning is
/// re-evaluated when the target's live commitments change. Presentation must
/// pass this through `conflictInstantsForLocalDay` and never expose item content.
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
