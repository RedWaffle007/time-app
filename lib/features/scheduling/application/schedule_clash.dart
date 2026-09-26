import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../groups/application/planner_access_reconciler.dart';
import '../domain/schedule_item.dart';
import '../domain/slot.dart';
import 'schedule_providers.dart';

/// What one clash check found for one person.
enum ClashResult {
  /// Nothing live at that minute.
  clear,

  /// A live plan already sits at that exact minute.
  clash,

  /// The schedule could not be read even after retries. Treated as "say
  /// nothing": the warning is advisory, and the create rules stay the
  /// authority on whether the save is allowed.
  unknown,
}

/// **A literal clash** (Batch G1, replaces Item 27's whole-day rule): a live
/// plan — outcome-less `pending`/`approved`, the same [blocksSlot] policy —
/// scheduled at the SAME MINUTE as [instantUtc]. Plans elsewhere in the day,
/// and settled or cancelled ones, never count.
///
/// Compared as absolute minutes, so each person's own timezone is already
/// folded in: the caller resolves the wall time in the target's zone first.
bool clashesAt(Iterable<ScheduleItem> items, DateTime instantUtc) {
  final minute = _epochMinute(instantUtc);
  return items.any(
    (item) =>
        blocksSlot(item) && _epochMinute(item.scheduledInstantUtc) == minute,
  );
}

int _epochMinute(DateTime instant) =>
    instant.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute;

/// Reads a target's schedule for the clash check without ever getting stuck
/// in a failed state.
///
/// The old check watched a long-lived listener: one `permission-denied` (a
/// grant seconds old, a token refresh, a group hint row not written yet)
/// terminated it for the rest of the app session. This does one fresh read per
/// check, retries with short pauses, and — for group-scoped access — writes the
/// planner's own `plannerAccess` hint before retrying. The hint write is
/// idempotent and is the same one `PlannerAccessReconciler` makes; it only ever
/// names a group the rules re-verify, so it grants nothing by itself.
class ScheduleClashChecker {
  ScheduleClashChecker({
    required this.fetch,
    required this.ensureAccess,
    this.retryDelays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
    ],
    this.attemptTimeout = const Duration(seconds: 8),
  });

  final Future<List<ScheduleItem>> Function(String targetUid) fetch;

  /// Provision group-scoped read access for [targetUid] via [groupId].
  final Future<void> Function(String targetUid, String groupId) ensureAccess;

  /// One pause before each retry; its length is the number of retries.
  final List<Duration> retryDelays;
  final Duration attemptTimeout;

  Future<ClashResult> check({
    required String targetUid,
    required DateTime instantUtc,
    String? groupId,
  }) async {
    var accessEnsured = false;
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      if (attempt > 0) {
        if (!accessEnsured && groupId != null && groupId.isNotEmpty) {
          accessEnsured = true;
          try {
            await ensureAccess(targetUid, groupId).timeout(attemptTimeout);
          } catch (_) {
            // A friendship-scoped target, or a grant that is really gone: the
            // retry below settles it either way.
          }
        }
        await Future<void>.delayed(retryDelays[attempt - 1]);
      }
      try {
        final items = await fetch(targetUid).timeout(attemptTimeout);
        return clashesAt(items, instantUtc)
            ? ClashResult.clash
            : ClashResult.clear;
      } catch (_) {
        // Retry.
      }
    }
    return ClashResult.unknown;
  }
}

final scheduleClashCheckerProvider = Provider<ScheduleClashChecker>((ref) {
  final repository = ref.watch(scheduleRepositoryProvider);
  final access = ref.watch(plannerAccessRepositoryProvider);
  return ScheduleClashChecker(
    fetch: repository.fetchItemsForTarget,
    ensureAccess: (targetUid, groupId) async {
      final me = ref.read(currentUidProvider);
      if (me == null || me == targetUid) return;
      await access.grant(
        plannerUid: me,
        targetUid: targetUid,
        groupId: groupId,
      );
    },
  );
});
