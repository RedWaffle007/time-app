import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

/// The single source of truth for rendering dates and times to the user.
///
/// Every user-facing time display routes through here so the whole app is
/// consistent: one locale (the device's, via [Localizations]) and one 12h/24h
/// decision (the device's setting, via [MediaQuery.alwaysUse24HourFormat]).
/// This is what stops one screen showing "9:00 PM" while another shows "21:00",
/// and what gets month/day names and field order right outside English.

String _locale(BuildContext context) => Localizations.localeOf(context).toString();

DateFormat _timeFormat(BuildContext context) {
  final locale = _locale(context);
  return MediaQuery.of(context).alwaysUse24HourFormat
      ? DateFormat.Hm(locale) //  e.g. 21:00
      : DateFormat.jm(locale); //  e.g. 9:00 PM (or locale default)
}

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
    formatTimeOfDay(context, TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60));
