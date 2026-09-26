import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// friendship seconds old, a token refresh) terminated it for the rest of the
/// app session. This does one fresh read per check and retries with short
/// pauses. Only a friend's schedule is readable (Batch G items 2 + 3); a group
/// member who is not a friend reads as [ClashResult.unknown], and the group
/// double-booking check does not rely on this read.
class ScheduleClashChecker {
  ScheduleClashChecker({
    required this.fetch,
    this.retryDelays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
    ],
    this.attemptTimeout = const Duration(seconds: 8),
  });

  final Future<List<ScheduleItem>> Function(String targetUid) fetch;

  /// One pause before each retry; its length is the number of retries.
  final List<Duration> retryDelays;
  final Duration attemptTimeout;

  Future<ClashResult> check({
    required String targetUid,
    required DateTime instantUtc,
  }) async {
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      if (attempt > 0) {
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
  return ScheduleClashChecker(fetch: repository.fetchItemsForTarget);
});
