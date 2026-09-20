import '../../../core/timezone/tz_resolver.dart';
import 'schedule_item.dart';

/// **The slot grid.** Pure — no plugins, no clock, no Firestore.
///
/// A slot is a fixed 30-minute DISPLAY bucket. It is NOT a duration on the
/// item: `ScheduleItem` carries an instant and has no duration field. Multiple
/// items may share a bucket; these helpers only group the target's schedule for
/// the planner preview and identify old lock documents during migration.

/// Minutes per display slot. Legacy Firestore lock ids were derived from it.
const int kSlotMinutes = 30;

const int _msPerSlot = kSlotMinutes * 60 * 1000;

/// The bucket an instant falls in, anchored to the UTC epoch.
///
/// **UTC-anchored, not wall-clock-anchored, and this is deliberate.** Anchoring
/// to the target's local clock reads better and is ambiguous twice a year: on a
/// fall-back date the local 01:30 bucket occurs twice, so one key would name two
/// different half-hours. That is the same class of bug `tz_resolver.dart` exists
/// to prevent. Epoch anchoring is total and monotone.
///
/// The cost, stated where it bites: in a zone whose offset is not a whole
/// half-hour (Kathmandu +05:45, Chatham +12:45) buckets begin at :15 and :45
/// local rather than :00 and :30.
///
/// `floor`, not `~/`: truncation rounds toward zero, which would put pre-epoch
/// instants in the bucket *after* the one containing them.
int slotIndexFor(DateTime instant) =>
    (instant.toUtc().millisecondsSinceEpoch / _msPerSlot).floor();

/// The instant a slot opens.
DateTime slotStartUtc(int index) =>
    DateTime.fromMillisecondsSinceEpoch(index * _msPerSlot, isUtc: true);

/// The instant a slot closes (exclusive).
DateTime slotEndUtc(int index) => slotStartUtc(index + 1);

/// The Firestore document id of a slot's lock, under
/// `scheduleSlots/{targetUid}/slots/{id}`.
///
/// A plain decimal index. Both parties compute it from the same instant, which
/// is what lets the rules engine treat a colliding `create` as the conflict —
/// it can construct the path, and it cannot run a query.
String slotLockId(int index) => index.toString();

/// Should this live item appear in its display slot?
///
/// Pending and approved items are useful schedule context. Rejected, withdrawn,
/// completed, and skipped items no longer belong in the live preview. Despite
/// the legacy name, a true result does not prevent another plan at that time.
bool blocksSlot(ScheduleItem item) =>
    item.outcome == null &&
    (item.status == ScheduleItemStatus.pending ||
        item.status == ScheduleItemStatus.approved);

/// The UTC half-open range `[start, end)` covered by one local calendar day in
/// [timezone].
///
/// Both ends go through `resolveWallTimeToUtc`, so a DST day is genuinely 23 or
/// 25 hours long here and the slot list that follows is 46 or 50 entries rather
/// than an assumed 48.
(DateTime, DateTime) localDayRangeUtc(DateTime localDay, String timezone) {
  final start = DateTime.utc(localDay.year, localDay.month, localDay.day);
  final next = start.add(const Duration(days: 1));
  return (
    resolveWallTimeToUtc(start, timezone),
    resolveWallTimeToUtc(
      DateTime.utc(next.year, next.month, next.day),
      timezone,
    ),
  );
}
