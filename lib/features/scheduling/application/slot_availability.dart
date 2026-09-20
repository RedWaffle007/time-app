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

  /// Commitments are informational. Items are point alarms with no duration,
  /// so another item in this display bucket never blocks selection.
  bool get isBlocked => false;

  /// The only thing the UI should ask before enabling a row.
  bool get isSelectable => !isPast;
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
    list.sort((a, b) => a.scheduledInstantUtc.compareTo(b.scheduledInstantUtc));
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

/// The legacy slot locks that should be RELEASED.
///
/// New items no longer create locks because they have no duration and may share
/// a half-hour. This function is retained as a migration cleanup: every lock
/// reachable from the target's item record is now stale and may be deleted.
///
/// Returns `slotIndex -> {ids of the items in that slot whose lock may go}`. The
/// caller deletes a lock only when its stored `itemId` is in the set — the
/// collision guard the legacy data needs, where two items can share a slot.
///
/// Items are never deleted (`allow delete: if false`), so every lock's owning
/// item is still somewhere in [items]; iterating them therefore reaches every
/// slot a leaked lock can occupy without listing the locks.
Map<int, Set<String>> releasableSlotLocks(
  List<ScheduleItem> items,
  DateTime now,
) {
  final releasable = <int, Set<String>>{};
  for (final item in items) {
    final index = slotIndexFor(item.scheduledInstantUtc);
    (releasable[index] ??= <String>{}).add(item.id);
  }
  return releasable;
}

/// Is this instant still in the future? Existing items never make it unavailable.
bool isInstantBookable({
  required DateTime instantUtc,
  required List<ScheduleItem> items,
  required DateTime now,
}) {
  if (!instantUtc.toUtc().isAfter(now.toUtc())) return false;
  return true;
}
