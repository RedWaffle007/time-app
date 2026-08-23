import '../domain/schedule_item.dart';
import '../domain/slot.dart';

/// **Everything about slot availability that can be wrong lives here.** Pure
/// functions over whatever the item stream currently says — no clock of their
/// own, no Firestore, no `BuildContext` — so `test/slot_availability_test.dart`
/// pins them without a device.

/// One row of the modal.
class TargetSlot {
  const TargetSlot({
    required this.index,
    required this.occupants,
    required this.isPast,
  });

  final int index;

  /// Live items claiming this slot, in start order. Usually zero or one; more
  /// than one is possible for pre-existing data, because the lock that prevents
  /// it was only introduced with this feature.
  final List<ScheduleItem> occupants;

  /// Already begun. Unselectable, but for a different reason than [isBlocked] —
  /// nothing is waiting on anyone here, so it is drawn as line work, not with a
  /// status colour (UI-RULES.md §6.11).
  final bool isPast;

  DateTime get startUtc => slotStartUtc(index);
  DateTime get endUtc => slotEndUtc(index);

  bool get isBlocked => occupants.isNotEmpty;

  /// The only thing the UI should ask before enabling a row.
  bool get isSelectable => !isBlocked && !isPast;
}

/// The slots covering one local day in the target's zone.
///
/// [localDay] is a field carrier — year/month/day as the planner picked them,
/// interpreted in [timezone]. [items] is the target's live stream, unfiltered;
/// this decides what counts.
List<TargetSlot> slotsForLocalDay({
  required DateTime localDay,
  required String timezone,
  required List<ScheduleItem> items,
  required DateTime now,
}) {
  final (dayStart, dayEnd) = localDayRangeUtc(localDay, timezone);

  final byIndex = <int, List<ScheduleItem>>{};
  for (final item in items) {
    if (!blocksSlot(item)) continue;
    byIndex
        .putIfAbsent(slotIndexFor(item.scheduledInstantUtc), () => [])
        .add(item);
  }
  for (final list in byIndex.values) {
    list.sort(
        (a, b) => a.scheduledInstantUtc.compareTo(b.scheduledInstantUtc));
  }

  final first = slotIndexFor(dayStart);
  // `dayEnd` is exclusive: a day ending exactly on a bucket boundary must not
  // pull in the first bucket of the next day.
  final last = slotIndexFor(dayEnd.subtract(const Duration(milliseconds: 1)));

  final nowUtc = now.toUtc();
  return [
    for (var i = first; i <= last; i++)
      TargetSlot(
        index: i,
        occupants: byIndex[i] ?? const [],
        // A slot that has already begun cannot be planned into. Measured on the
        // START, not the end: half of a slot in progress is still the past.
        isPast: !slotStartUtc(i).isAfter(nowUtc),
      ),
  ];
}

/// The first selectable slot at or after [from], or null if the day has none.
///
/// Powers the "next free at …" hint. A hint, never a substitute for blocking —
/// the planner still has to choose.
TargetSlot? nextFreeSlot(List<TargetSlot> slots, {int? from}) {
  for (final slot in slots) {
    if (from != null && slot.index < from) continue;
    if (slot.isSelectable) return slot;
  }
  return null;
}

/// The slot locks that should be RELEASED, given the target's current items.
///
/// **The self-healing half of the lock's lifecycle.** `createItem` writes a lock
/// in the same batch as the item, but the only release paths are `withdraw()`
/// and `reject()` — a completed or skipped item keeps its lock forever, and any
/// release write that missed (offline) leaks one too. Both leave a stale lock
/// that blocks a half-hour the UI already shows as free, because the UI reads
/// the item stream (`blocksSlot`) while the write-race guard reads the lock.
///
/// This closes that gap the same way `desiredReminders()` and
/// `desiredPlanners()` close theirs: one rule over whatever the stream currently
/// says, not a per-transition hook.
///
/// **The rule keys on the SLOT, not on the item's status: a lock is kept only
/// for a live item whose slot is still in the FUTURE; every past slot's lock is
/// released regardless of status.** A lock exists to stop double-booking a
/// bookable half-hour — and a past half-hour is not bookable (`isInstantBookable`
/// and `isPast` both forbid it), so its lock is pure cruft. Keying on status
/// alone stranded the locks of items that FIRED but carry no outcome — the
/// default ending of the full-screen alarm's Dismiss (silence, not markDone) and
/// of any reminder simply left unmarked. Those read `blocksSlot == true` forever,
/// so their slot never freed. The time dimension is what makes this cover EVERY
/// termination path — done, skipped, rejected, withdrawn, alarm-dismissed, and
/// fired-and-never-touched — because they all reduce to "the slot is no longer a
/// bookable future half-hour". [now] must be UTC.
///
/// Returns `slotIndex -> {ids of the items in that slot whose lock may go}`. The
/// caller deletes a lock only when its stored `itemId` is in the set — the
/// collision guard the pre-lock legacy data needs, where two items can share a
/// slot. A slot that still holds a live FUTURE item is excluded outright, so a
/// genuine upcoming booking is never freed out from under itself.
///
/// Items are never deleted (`allow delete: if false`), so every lock's owning
/// item is still somewhere in [items]; iterating them therefore reaches every
/// slot a leaked lock can occupy without listing the locks.
Map<int, Set<String>> releasableSlotLocks(List<ScheduleItem> items, DateTime now) {
  final nowUtc = now.toUtc();
  // Slots whose lock must stay: a live item AND the slot has not begun yet, so
  // it is still a bookable half-hour. `isAfter(now)` matches the `isPast` rule in
  // `slotsForLocalDay` (a slot in progress is already the past).
  final keep = <int>{};
  for (final item in items) {
    final index = slotIndexFor(item.scheduledInstantUtc);
    if (blocksSlot(item) && slotStartUtc(index).isAfter(nowUtc)) keep.add(index);
  }
  final releasable = <int, Set<String>>{};
  for (final item in items) {
    final index = slotIndexFor(item.scheduledInstantUtc);
    if (keep.contains(index)) continue; // a live, future item still needs it
    (releasable[index] ??= <String>{}).add(item.id);
  }
  return releasable;
}

/// Is this exact instant bookable against the target's current schedule?
///
/// **The same predicate the modal draws with**, applied to the instant actually
/// about to be written. Called once more at submit time, because the modal's
/// view can be seconds stale — and then the write is guarded again by the slot
/// lock, which is the only check that is authoritative.
bool isInstantBookable({
  required DateTime instantUtc,
  required List<ScheduleItem> items,
  required DateTime now,
}) {
  if (!instantUtc.toUtc().isAfter(now.toUtc())) return false;
  final index = slotIndexFor(instantUtc);
  return !items.any(
    (i) => blocksSlot(i) && slotIndexFor(i.scheduledInstantUtc) == index,
  );
}
