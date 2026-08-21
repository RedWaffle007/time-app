import 'package:timezone/timezone.dart' as tz;

import '../../scheduling/domain/schedule_item.dart';

/// **The calendar's pure layer.** No plugins, no clock, no Firestore, no
/// `BuildContext` — the same discipline as `reminder_policy.dart`, and for the
/// same reason: all the logic that can be *wrong* lives here, so it can be
/// tested without a device.
///
/// The calendar itself stores nothing. Everything below is a projection of the
/// item stream that already exists (DECISIONS.md → "In-app calendar").

/// Which side of the delegation loop the viewer is on for one item.
///
/// Not a boolean, because the two sides read differently on a card ("18:30
/// German practice" versus "14:00 Gym session · for Sam") and a bare `bool
/// isMine` at a call site does not say which way round it is.
enum CalendarSide {
  /// The viewer is the TARGET — this is on their own schedule.
  mine,

  /// The viewer created it FOR someone else.
  planned,
}

/// One item as the calendar sees it: the item, plus the viewer's relationship
/// to it. The item alone is not enough — the same document renders differently
/// depending on which end of it you are.
class CalendarEntry {
  const CalendarEntry({required this.item, required this.side});

  final ScheduleItem item;
  final CalendarSide side;

  /// The item's wall clock **in its own timezone** — see [itemWallTime].
  DateTime get wallTime => itemWallTime(item);

  /// The grid cell this entry belongs in.
  DateTime get day => calendarDayFor(item);
}

/// An item's wall-clock time in **its own** timezone, as a field carrier.
///
/// The returned `DateTime` is UTC-kind and is **not an instant** — it is the
/// year/month/day/hour/minute the user sees on the card, packed into a
/// `DateTime` so they can be compared and truncated. This is the same carrier
/// trick `ScheduleBuilderScreen._wall()` uses when going the other way, and for
/// the same reason: a local-kind `DateTime(...)` would be silently renormalized
/// by the *device's* zone if those fields land in a DST gap there.
///
/// The zone is the item's own, never the viewer's. `formatInstant` already
/// renders the card that way, so bucketing by anything else would file a card
/// reading "Tue 9:00 AM" under Monday.
///
/// An unknown or empty `timezone` (a malformed document) falls back to the
/// device zone rather than throwing. One bad document must not take the whole
/// grid down — and it has somewhere plausible to appear, which is better than
/// vanishing.
DateTime itemWallTime(ScheduleItem item) {
  final instant = item.scheduledInstantUtc;
  DateTime local;
  try {
    local = tz.TZDateTime.from(instant, tz.getLocation(item.timezone));
  } catch (_) {
    local = instant.toLocal();
  }
  return DateTime.utc(
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute,
  );
}

/// The grid cell an item belongs in: [itemWallTime] with the time dropped.
///
/// UTC-kind and midnight, matching `table_calendar`'s own `normalizeDate`, so
/// these compare equal as `Map` keys and as `isSameDay` arguments.
DateTime calendarDayFor(ScheduleItem item) {
  final wall = itemWallTime(item);
  return DateTime.utc(wall.year, wall.month, wall.day);
}

/// Truncate any date to the same UTC-midnight key shape.
DateTime calendarDayKey(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

/// Merge the two item streams into the viewer's calendar.
///
/// Deduplicated by id, and **the target side wins**: a self-planned item is in
/// both streams (the user is creator *and* target), exactly as
/// `archivedItemsProvider` already has to handle. It is your own schedule, so it
/// reads as [CalendarSide.mine] rather than as something you planned for
/// someone.
///
/// [viewerUid] null (signed out mid-frame) yields an empty calendar rather than
/// mislabelling every entry.
List<CalendarEntry> calendarEntries({
  required List<ScheduleItem> asTarget,
  required List<ScheduleItem> asPlanner,
  required String? viewerUid,
}) {
  if (viewerUid == null) return const [];

  final byId = <String, CalendarEntry>{};
  // Planner side first, so the target pass overwrites it for a self-planned
  // item. Order here IS the dedup rule; do not reorder these two loops.
  for (final item in asPlanner) {
    byId[item.id] = CalendarEntry(item: item, side: CalendarSide.planned);
  }
  for (final item in asTarget) {
    byId[item.id] = CalendarEntry(item: item, side: CalendarSide.mine);
  }
  return byId.values.toList()..sort(_byInstantThenTitle);
}

/// Index entries by grid cell, each day's list in the order it is drawn.
///
/// Built once per stream emission and read by every cell, rather than each cell
/// filtering the whole list — a month is 42 cells, and a linear scan in each is
/// 42 passes over every item the user has.
Map<DateTime, List<CalendarEntry>> groupEntriesByDay(
  List<CalendarEntry> entries,
) {
  final byDay = <DateTime, List<CalendarEntry>>{};
  for (final entry in entries) {
    byDay.putIfAbsent(entry.day, () => <CalendarEntry>[]).add(entry);
  }
  for (final list in byDay.values) {
    list.sort(_byInstantThenTitle);
  }
  return byDay;
}

/// Everything on one day, in draw order. Empty for a free day.
List<CalendarEntry> entriesOn(
  Map<DateTime, List<CalendarEntry>> byDay,
  DateTime day,
) =>
    byDay[calendarDayKey(day)] ?? const [];

/// Group one day's entries by the hour they fall in, for the day view's rail.
///
/// Keyed by the hour in the ITEM's zone, which is the hour printed on its card.
/// With items from several zones on one day, two entries in the same rail row
/// can be hours apart in real time — that is what a cross-timezone plan
/// genuinely is, and hiding it would be the lie.
Map<int, List<CalendarEntry>> groupEntriesByHour(List<CalendarEntry> entries) {
  final byHour = <int, List<CalendarEntry>>{};
  for (final entry in entries) {
    byHour.putIfAbsent(entry.wallTime.hour, () => <CalendarEntry>[]).add(entry);
  }
  for (final list in byHour.values) {
    list.sort(_byInstantThenTitle);
  }
  return byHour;
}

/// The hour the day view should open on: the first item's, or 8am on a free
/// day. Never the current hour on a day that is not today — scrolling a future
/// Saturday to 3pm because that is what time it is now would be noise.
int openingHourFor({
  required List<CalendarEntry> entries,
  required bool isToday,
  required int nowHour,
}) {
  if (entries.isNotEmpty) return entries.first.wallTime.hour;
  if (isToday) return nowHour;
  return 8;
}

/// Instant first — a calendar is a time axis. Title breaks the tie so the order
/// is stable across rebuilds; two items at the same minute would otherwise swap
/// places on every emission, since `Map.values` order is insertion order and
/// insertion order follows Firestore's.
int _byInstantThenTitle(CalendarEntry a, CalendarEntry b) {
  final byInstant =
      a.item.scheduledInstantUtc.compareTo(b.item.scheduledInstantUtc);
  if (byInstant != 0) return byInstant;
  final byTitle = a.item.title.compareTo(b.item.title);
  return byTitle != 0 ? byTitle : a.item.id.compareTo(b.item.id);
}
