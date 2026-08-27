/// **The pure end-of-day lapse rule, kept off the clock and off Firestore.**
///
/// An unaddressed item cannot sit in "next" forever. At the END OF ITS OWN LOCAL
/// DAY (midnight in `item.timezone`, never the viewer's zone) anything still
/// unaddressed auto-resolves:
///
///   * a still-`pending` plan the target never approved  → rejected
///     ("Not approved in time" — it was never a commitment, so there is no
///     delay to record);
///   * an `approved` item with no outcome the target never acted on → skipped
///     ("Did not respond").
///
/// Both stay VISIBLE (settled with a badge), never deleted — the accountability
/// partner still sees what happened. A LATE completion (done after the scheduled
/// time but before end of day) is a normal Done, honest data: its delay is
/// carried by `ScheduleItem.completionDelay`, derived from `completedAt`.
///
/// Everything here is a pure function of the items and an injected `now`, which
/// is what `test/item_lapse_test.dart` pins without a device — same doctrine as
/// `reminder_policy.dart`.
library;

import 'package:timezone/timezone.dart' as tz;

import '../domain/schedule_item.dart';

/// The skip reason stamped on an approved item nobody acted on by end of day.
const kLapsedSkipReason = 'Did not respond';

/// The rejection reason stamped on a pending item nobody approved by end of day.
const kLapsedRejectReason = 'Not approved in time';

/// The instant [item] lapses if still unaddressed: midnight ending its OWN local
/// day (in `item.timezone`). Until this instant the item stays fully actionable,
/// so the user has the whole day to respond — and to complete late.
///
/// Built via [tz.TZDateTime] so the day boundary lands on real local midnight
/// even across a DST shift (a "day + 1" rolls the calendar, not a fixed 24h). An
/// unknown/empty zone falls back to a UTC day boundary so a bad zone can neither
/// make an item immortal nor lapse it early on a device-zone guess.
DateTime endOfScheduledLocalDayUtc(ScheduleItem item) {
  final tz.Location location;
  try {
    location = tz.getLocation(item.timezone);
  } catch (_) {
    final utc = item.scheduledInstantUtc.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day)
        .add(const Duration(days: 1));
  }
  final local = tz.TZDateTime.from(item.scheduledInstantUtc, location);
  // day + 1 → the first instant of the next local day; TZDateTime normalizes the
  // month/year overflow and applies the zone's offset for that exact midnight.
  return tz.TZDateTime(location, local.year, local.month, local.day + 1).toUtc();
}

/// Whether [item]'s local day has ended as of [nowUtc].
bool hasLapsed(ScheduleItem item, DateTime nowUtc) =>
    !nowUtc.toUtc().isBefore(endOfScheduledLocalDayUtc(item));

/// The two auto-resolutions [items] currently imply, as of [nowUtc].
class LapsedItems {
  const LapsedItems({required this.toReject, required this.toSkip});

  /// Pending items past their local day — to be rejected "not approved in time".
  final List<ScheduleItem> toReject;

  /// Approved, outcome-less items past their local day — to be skipped
  /// "did not respond".
  final List<ScheduleItem> toSkip;

  bool get isEmpty => toReject.isEmpty && toSkip.isEmpty;
}

/// Classify [items] into the lapse actions due as of [nowUtc]. Only pending and
/// approved-without-outcome items are ever touched; everything already settled
/// (rejected, withdrawn, done, skipped) is skipped, which is what makes applying
/// this on every stream emission idempotent.
LapsedItems lapsedItems(List<ScheduleItem> items, DateTime nowUtc) {
  final toReject = <ScheduleItem>[];
  final toSkip = <ScheduleItem>[];
  for (final item in items) {
    if (!hasLapsed(item, nowUtc)) continue;
    if (item.status == ScheduleItemStatus.pending) {
      toReject.add(item);
    } else if (item.status == ScheduleItemStatus.approved &&
        item.outcome == null) {
      toSkip.add(item);
    }
  }
  return LapsedItems(toReject: toReject, toSkip: toSkip);
}
