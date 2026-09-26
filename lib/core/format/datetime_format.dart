import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

/// The single source of truth for rendering dates and times to the user.
///
/// Every user-facing time display routes through here so the whole app is
/// consistent: one locale (the device's, via [Localizations]) and one 12h/24h
/// decision (the device's setting, via [MediaQuery.alwaysUse24HourFormat]).
///
/// F1 (2026-09-26): the app sets `alwaysUse24HourFormat` from the PHONE's real
/// clock setting (see `device_clock.dart`), and the 12-hour patterns below are
/// explicit — never the language's default, which is 24-hour for e.g. English
/// (UK/India) and made a 12-hour phone show 24-hour times.
/// This is what stops one screen showing "9:00 PM" while another shows "21:00",
/// and what gets month/day names and field order right outside English.

String _locale(BuildContext context) =>
    Localizations.localeOf(context).toString();

DateFormat _timeFormat(BuildContext context) {
  final locale = _locale(context);
  if (MediaQuery.of(context).alwaysUse24HourFormat) {
    return DateFormat.Hm(locale); //  e.g. 21:00
  }
  // The language's own 12-hour form where it has one (keeps its spacing,
  // e.g. the narrow no-break space in "9:00 PM"); an explicit 12-hour form
  // only for languages whose default is 24-hour (F1).
  final native = DateFormat.jm(locale);
  return _is12Hour(native) ? native : DateFormat('h:mm a', locale);
}

/// Whether a CLDR pattern is 12-hour (it carries a day-period field).
bool _is12Hour(DateFormat format) => (format.pattern ?? '').contains('a');

/// An absolute instant rendered in [ianaZone], localized. Replaces the old
/// English-only, always-24h `formatInZone`.
String formatInstant(
  BuildContext context,
  DateTime utcInstant,
  String ianaZone,
) {
  final t = tz.TZDateTime.from(utcInstant, tz.getLocation(ianaZone));
  final date = DateFormat.yMMMEd(_locale(context)).format(t);
  return '$date, ${_timeFormat(context).format(t)}';
}

/// An absolute instant in the PHONE's own zone, localized — for things that
/// belong to this device's user rather than to a plan's target (the voice
/// library's default note names, 32d).
String formatLocalInstant(BuildContext context, DateTime utcInstant) {
  final t = utcInstant.toLocal();
  final date = DateFormat.yMMMEd(_locale(context)).format(t);
  return '$date, ${_timeFormat(context).format(t)}';
}

/// Just the time part of an absolute instant in [ianaZone], localized.
///
/// Same clock and locale decisions as [formatInstant] — this is that function
/// with the date dropped, for the one place the date is already established by
/// its surroundings (the hero band, which is showing today).
String formatInstantTime(
  BuildContext context,
  DateTime utcInstant,
  String ianaZone,
) {
  final t = tz.TZDateTime.from(utcInstant, tz.getLocation(ianaZone));
  return _timeFormat(context).format(t);
}

/// A wall-clock date with no zone (e.g. the date-picker button label).
String formatWallDate(BuildContext context, DateTime date) =>
    DateFormat.yMMMEd(_locale(context)).format(date);

/// A time-of-day, localized and 12/24h-aware (quiet-hours labels, the
/// time-picker button) — kept identical to [formatInstant]'s time part so a
/// picked time and its preview always match.
String formatTimeOfDay(BuildContext context, TimeOfDay time) =>
    _timeFormat(context).format(DateTime(2000, 1, 1, time.hour, time.minute));

/// Minutes-since-midnight (how quiet hours are stored) as a localized time.
String formatMinutesOfDayLocalized(BuildContext context, int minutes) =>
    formatTimeOfDay(
      context,
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
    );

/// A DURATION in whole minutes, rendered per the unit rule: minutes are the
/// base, hours appear only past 59 — "45 min", "1h 30m", "2h". Digits are
/// localized (worldwide requirement), so this is the one helper every tracked
/// duration renders through, never a hand-built `'$m min'`.
///
/// The unit abbreviations (`min` / `h` / `m`) are fixed and not localized —
/// matching how the app already renders compact time — so a full-locale unit
/// translation, if ever wanted, lands here in one place.
String formatDurationMinutes(BuildContext context, int minutes) {
  final n = NumberFormat.decimalPattern(_locale(context));
  if (minutes < 60) return '${n.format(minutes)} min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${n.format(h)}h' : '${n.format(h)}h ${n.format(m)}m';
}

// ---------------------------------------------------------------------------
// The calendar (UI-RULES.md §6.10).
//
// These exist because `table_calendar` renders its own cells with
// `'${day.day}'` — Latin digits, hardcoded. In a locale that writes its own
// numerals that is a silent regression of the standing worldwide requirement,
// with nothing to catch it. Routing every day number, weekday name and hour
// label through here is what lets the calendar draw all its own cells.
// ---------------------------------------------------------------------------

/// The month and year heading over a month or week grid, e.g. "August 2026".
String formatMonthYear(BuildContext context, DateTime date) =>
    DateFormat.yMMMM(_locale(context)).format(date);

/// One day number inside a grid cell. Localized digits — NOT `'${date.day}'`.
String formatDayOfMonth(BuildContext context, DateTime date) =>
    DateFormat.d(_locale(context)).format(date);

/// An abbreviated weekday for the grid's column headers, e.g. "Tue".
String formatWeekdayShort(BuildContext context, DateTime date) =>
    DateFormat.E(_locale(context)).format(date);

/// A day heading over an agenda or the day view, e.g. "Tue, Aug 25".
///
/// Deliberately without the year: it is already stated by the month heading
/// directly above it, and repeating it crowds the one line that has to stay
/// scannable.
String formatDayHeadingShort(BuildContext context, DateTime date) =>
    DateFormat.MMMEd(_locale(context)).format(date);

/// The label on one hour row of the day view, e.g. "9 AM" or "09".
///
/// Same 12h/24h decision as every other time in the app — [MediaQuery]'s
/// `alwaysUse24HourFormat`, never a guess from the locale alone.
String formatHourOfDay(BuildContext context, int hour) {
  final locale = _locale(context);
  final native = DateFormat.j(locale);
  final format = MediaQuery.of(context).alwaysUse24HourFormat
      ? DateFormat.H(locale)
      : (_is12Hour(native) ? native : DateFormat('h a', locale));
  return format.format(DateTime(2000, 1, 1, hour));
}

/// The time part of a WALL-CLOCK carrier — a `DateTime` whose fields are
/// already the local time in some other zone (what `itemWallTime()` returns).
///
/// Distinct from [formatInstantTime], which takes a real instant and a zone to
/// resolve it in. Passing a carrier to that one would re-interpret fields that
/// have already been resolved; passing an instant to this one would render it
/// in the wrong zone. The two must not be swapped.
String formatWallTimeOfDay(BuildContext context, DateTime wall) =>
    _timeFormat(context).format(DateTime(2000, 1, 1, wall.hour, wall.minute));
