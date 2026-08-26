/// **The fallible core of voice capture, kept pure.** No plugins, no clock, no
/// Firestore — every branch that can misread an utterance lives here, which is
/// why `test/voice_parsers_test.dart` can pin all of it without a device (same
/// doctrine as `reminder_policy.dart`).
///
/// **Neither parser ever commits anything.** Both only produce a DRAFT that
/// pre-fills the existing editable sheet/builder, so a misparse is a visible
/// edit the user corrects, never a bad write. When a field cannot be read it is
/// left null/empty for the user to fill — the parser guesses toward "leave it
/// blank", not toward a confident wrong value.
///
/// **English-only, deliberately, for v1.** The worldwide requirement governs
/// how times/dates are RENDERED (the prefilled values still flow through the one
/// format helper); it does not require multilingual speech parsing. This is a
/// logged limitation (DECISIONS.md → S6).
library;

import 'package:flutter/material.dart' show TimeOfDay;

/// What "Track time" voice capture yields: a task name and, when a duration was
/// clearly stated, the minutes. [minutes] is null when no `<number> <unit>`
/// group was found — the log sheet then focuses its empty minutes field.
class TrackDraft {
  const TrackDraft({required this.taskName, this.minutes});

  final String taskName;
  final int? minutes;
}

/// What "Plan time" voice capture yields: a title, and the day/time when they
/// were recognised. Any of [date]/[time] may be null; the builder's `_canSave`
/// still requires all three, so an incomplete draft cannot submit straight
/// through.
///
/// [date] is a wall date (year/month/day only) meant to be interpreted in the
/// TARGET's timezone, exactly like the calendar-seeded `initialDate`.
class PlanDraft {
  const PlanDraft({this.date, this.time, required this.title});

  final DateTime? date;
  final TimeOfDay? time;
  final String title;
}

// ── Track ─────────────────────────────────────────────────────────────────

/// Parse a Track utterance shaped "[task] [duration]", e.g. "walking 30 mins"
/// → task "walking", 30 min. The duration is the LAST `<number> <unit>` group;
/// everything before it is the task. A bare trailing number with no unit
/// ("route 66") stays part of the task — a unit token is required to read a
/// duration, so a number that is really part of the name is not mistaken for one.
TrackDraft parseTrackUtterance(String utterance) {
  final original = _collapseSpaces(utterance);
  if (original.isEmpty) return const TrackDraft(taskName: '');

  final tokens = original.split(' ');
  final lower = tokens.map((t) => _stripPunct(t.toLowerCase())).toList();

  // A fused token like "30min"/"45mins"/"1.5h" — split it so the unit scan sees
  // a distinct unit token, without disturbing the original casing used for the
  // task text (a fused token is never part of the task anyway).
  final fused = RegExp(r'^(\d+(?:\.\d+)?)(m|min|mins|minute|minutes'
      r'|h|hr|hrs|hour|hours)$');

  // Find the last unit token (possibly fused).
  var unitIdx = -1;
  var fusedNumber = <String>[];
  var unitIsHours = false;
  for (var i = lower.length - 1; i >= 0; i--) {
    final m = fused.firstMatch(lower[i]);
    if (m != null) {
      unitIdx = i;
      fusedNumber = [m.group(1)!];
      unitIsHours = m.group(2)!.startsWith('h');
      break;
    }
    if (_minuteUnits.contains(lower[i]) || _hourUnits.contains(lower[i])) {
      unitIdx = i;
      unitIsHours = _hourUnits.contains(lower[i]);
      break;
    }
  }

  if (unitIdx == -1) {
    // No duration stated — the whole utterance is the task.
    return TrackDraft(taskName: original);
  }

  // Gather the number phrase immediately before the unit (unless fused).
  int numberStart;
  double? value;
  if (fusedNumber.isNotEmpty) {
    numberStart = unitIdx;
    value = double.tryParse(fusedNumber.first);
  } else {
    var j = unitIdx - 1;
    while (j >= 0 && _isNumberWord(lower[j])) {
      j--;
    }
    numberStart = j + 1;
    var numWords = lower.sublist(numberStart, unitIdx);
    // A trailing "a"/"an" is the article of the unit, not a number: "half an
    // hour" is 0.5 hour, not 1.5. Drop it — but only when there is another
    // number word to keep, so a bare "an hour" still reads as 1.
    if (numWords.length > 1 &&
        (numWords.last == 'a' || numWords.last == 'an')) {
      numWords = numWords.sublist(0, numWords.length - 1);
    }
    value = _phraseToNumber(numWords);
  }

  // "... and a half" / "... and a quarter" AFTER the unit, e.g. "an hour and a
  // half" → +30 min.
  var extraMinutes = 0.0;
  final tail = lower.sublist((unitIdx + 1).clamp(0, lower.length));
  if (tail.length >= 3 &&
      tail[0] == 'and' &&
      (tail[1] == 'a' || tail[1] == 'an')) {
    if (tail[2] == 'half') {
      extraMinutes = unitIsHours ? 30 : 0.5;
    } else if (tail[2] == 'quarter') {
      extraMinutes = unitIsHours ? 15 : 0.25;
    }
  }

  if (value == null) {
    // A unit with no readable number ("walking minutes") — keep the words as
    // task, no duration.
    return TrackDraft(taskName: original);
  }

  final minutes = (value * (unitIsHours ? 60 : 1) + extraMinutes).round();
  // The task is everything before the number; tokens at/after the number never
  // leak in. If it ends up empty, the sheet focuses the name field.
  final task = tokens.sublist(0, numberStart).join(' ').trim();
  // Clamp to a valid entry is the sheet's job (1..1440); a value under a minute
  // is treated as "no duration stated".
  return TrackDraft(taskName: task, minutes: minutes < 1 ? null : minutes);
}

// ── Plan ──────────────────────────────────────────────────────────────────

/// Parse a Plan utterance shaped "[Day][Time][Alarm name]", e.g.
/// "Monday 7am gym" → next Monday, 07:00, title "gym". Order-tolerant: the day
/// and time are found wherever they sit and removed; what remains is the title.
///
/// The day may be a weekday ("Monday"), "today"/"tomorrow", OR an explicit
/// calendar date ("30 Aug", "August 30th", "30 August 2027") — see
/// [_findCalendarDate].
///
/// [now] is injected (not read from a clock) so weekday resolution is pure and
/// testable. A bare weekday resolves to its nearest occurrence including today.
PlanDraft parsePlanUtterance(String utterance, {required DateTime now}) {
  final original = _collapseSpaces(utterance);
  if (original.isEmpty) return const PlanDraft(title: '');

  final tokens = original.split(' ');
  final lower = tokens.map((t) => _stripPunct(t.toLowerCase())).toList();

  // Track which token indices are consumed by day/time so the remainder is the
  // title.
  final consumed = List<bool>.filled(tokens.length, false);

  // ── Day ──
  DateTime? date;
  var fromWeekday = false; // date came from a bare weekday name (rolls forward)
  for (var i = 0; i < lower.length; i++) {
    final w = lower[i];
    if (w == 'today') {
      date = _dateOnly(now);
      consumed[i] = true;
      break;
    }
    if (w == 'tomorrow') {
      date = _dateOnly(now.add(const Duration(days: 1)));
      consumed[i] = true;
      break;
    }
    final wd = _weekday(w);
    if (wd != null) {
      final delta = (wd - now.weekday + 7) % 7; // 0..6, today if same weekday
      date = _dateOnly(now.add(Duration(days: delta)));
      consumed[i] = true;
      fromWeekday = true;
      break;
    }
  }

  // No weekday/today/tomorrow → try an explicit calendar date ("30 aug").
  date ??= _findCalendarDate(lower, consumed, now);

  // ── Time ──
  final time = _findTime(lower, consumed);

  // A bare weekday must land on its NEXT occurrence, never one already gone.
  // The weekday match above includes today (delta 0), so "Monday" said on a
  // Monday afternoon with a morning time would resolve to this morning — a past
  // instant. When the resolved day+time is not in the future, roll to next
  // week. Only weekday-sourced dates roll: "today"/"tomorrow"/an explicit
  // calendar date are taken as said (a past "today 9am" is the speaker's error,
  // caught by the builder's hard past-guard, not silently moved a week). `now`
  // here is the device clock; the builder re-checks the instant in the target's
  // zone, so this is the sensible-default layer, not the guarantee.
  if (fromWeekday && date != null && time != null) {
    final instant =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!instant.isAfter(now)) {
      date = _dateOnly(date.add(const Duration(days: 7)));
    }
  }

  // ── Title ── everything not consumed, minus edge filler words.
  final titleTokens = <String>[];
  for (var i = 0; i < tokens.length; i++) {
    if (!consumed[i]) titleTokens.add(tokens[i]);
  }
  final title = _trimFiller(titleTokens);

  return PlanDraft(date: date, time: time, title: title);
}

// ── Time recognition ────────────────────────────────────────────────────────

TimeOfDay? _findTime(List<String> lower, List<bool> consumed) {
  // "noon" / "midnight" / "midday"
  for (var i = 0; i < lower.length; i++) {
    switch (lower[i]) {
      case 'noon':
      case 'midday':
        consumed[i] = true;
        return const TimeOfDay(hour: 12, minute: 0);
      case 'midnight':
        consumed[i] = true;
        return const TimeOfDay(hour: 0, minute: 0);
    }
  }

  // "7:30", "19:00", optionally followed by am/pm.
  for (var i = 0; i < lower.length; i++) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(lower[i]);
    if (m != null) {
      var h = int.parse(m.group(1)!);
      final min = int.parse(m.group(2)!);
      if (min > 59 || h > 23) continue;
      consumed[i] = true;
      h = _applyMeridian(h, _meridianAt(lower, i + 1, consumed));
      return TimeOfDay(hour: h % 24, minute: min);
    }
  }

  // Fused "7am" / "7pm" / "7:30pm".
  for (var i = 0; i < lower.length; i++) {
    final m = RegExp(r'^(\d{1,2})(?::(\d{2}))?(am|pm)$').firstMatch(lower[i]);
    if (m != null) {
      final h = int.parse(m.group(1)!);
      final min = m.group(2) == null ? 0 : int.parse(m.group(2)!);
      if (h > 12 || h < 1 || min > 59) continue;
      consumed[i] = true;
      return TimeOfDay(hour: _applyMeridian(h, m.group(3)), minute: min);
    }
  }

  // "half past seven", "quarter past seven", "quarter to eight".
  final phrase = _relativeClockPhrase(lower, consumed);
  if (phrase != null) return phrase;

  // "seven thirty", "seven o'clock", bare "seven" + am/pm.
  for (var i = 0; i < lower.length; i++) {
    final base = _clockNumber(lower[i]);
    if (base == null || base > 12 || base < 1) continue;
    // Next token: "thirty"/"fifteen"/... as minutes, "o'clock", or am/pm.
    var minute = 0;
    var end = i;
    final mer = _meridianAt(lower, i + 1, consumed, mark: false);
    if (i + 1 < lower.length) {
      final next = lower[i + 1];
      final asMin = _phraseToNumber([next]);
      if (next == "o'clock" || next == 'oclock' || next == 'oclock') {
        end = i + 1;
      } else if (asMin != null && asMin >= 0 && asMin <= 59) {
        minute = asMin.round();
        end = i + 1;
      }
    }
    // Only treat a bare number as a time if a meridian or a minute/o'clock made
    // it clock-shaped — otherwise "seven" is probably part of the title.
    final merEnd = _meridianAt(lower, end + 1, consumed, mark: false);
    if (end == i && mer == null && merEnd == null) continue;
    for (var k = i; k <= end; k++) {
      consumed[k] = true;
    }
    final chosenMer = merEnd ?? mer;
    if (chosenMer != null) _markMeridian(lower, end + 1, consumed);
    return TimeOfDay(hour: _applyMeridian(base, chosenMer), minute: minute);
  }

  return null;
}

TimeOfDay? _relativeClockPhrase(List<String> lower, List<bool> consumed) {
  for (var i = 0; i + 2 < lower.length; i++) {
    final a = lower[i], b = lower[i + 1];
    final isHalf = a == 'half' && b == 'past';
    final isQuarterPast = a == 'quarter' && b == 'past';
    final isQuarterTo = a == 'quarter' && (b == 'to' || b == 'til');
    if (!isHalf && !isQuarterPast && !isQuarterTo) continue;
    final base = _clockNumber(lower[i + 2]);
    if (base == null || base > 12 || base < 1) continue;
    final mer = _meridianAt(lower, i + 3, consumed, mark: false);
    var hour = _applyMeridian(base, mer);
    var minute = 0;
    if (isHalf) {
      minute = 30;
    } else if (isQuarterPast) {
      minute = 15;
    } else {
      // quarter TO: 45 minutes past the previous hour.
      minute = 45;
      hour = (hour - 1 + 24) % 24;
    }
    for (var k = i; k <= i + 2; k++) {
      consumed[k] = true;
    }
    if (mer != null) _markMeridian(lower, i + 3, consumed);
    return TimeOfDay(hour: hour, minute: minute);
  }
  return null;
}

/// The meridian token ("am"/"pm") at [idx], if present. When [mark] is true and
/// found, the token is consumed.
String? _meridianAt(List<String> lower, int idx, List<bool> consumed,
    {bool mark = true}) {
  if (idx < 0 || idx >= lower.length) return null;
  final w = lower[idx];
  if (w == 'am' || w == 'pm') {
    if (mark) consumed[idx] = true;
    return w;
  }
  return null;
}

void _markMeridian(List<String> lower, int idx, List<bool> consumed) {
  if (idx >= 0 && idx < lower.length && (lower[idx] == 'am' || lower[idx] == 'pm')) {
    consumed[idx] = true;
  }
}

int _applyMeridian(int hour, String? meridian) {
  if (meridian == 'pm') return hour == 12 ? 12 : hour + 12;
  if (meridian == 'am') return hour == 12 ? 0 : hour;
  return hour; // no meridian → take the number as-is (24h or the user edits)
}

// ── Number & word helpers ────────────────────────────────────────────────────

const _minuteUnits = {'m', 'min', 'mins', 'minute', 'minutes'};
const _hourUnits = {'h', 'hr', 'hrs', 'hour', 'hours'};

const _ones = {
  'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
  'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11,
  'twelve': 12, 'thirteen': 13, 'fourteen': 14, 'fifteen': 15,
  'sixteen': 16, 'seventeen': 17, 'eighteen': 18, 'nineteen': 19,
};
const _tens = {
  'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50,
};
const _weekdays = {
  'monday': 1, 'mon': 1, 'tuesday': 2, 'tue': 2, 'tues': 2,
  'wednesday': 3, 'wed': 3, 'weds': 3, 'thursday': 4, 'thu': 4, 'thur': 4,
  'thurs': 4, 'friday': 5, 'fri': 5, 'saturday': 6, 'sat': 6,
  'sunday': 7, 'sun': 7,
};

const _months = {
  'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3,
  'apr': 4, 'april': 4, 'may': 5, 'jun': 6, 'june': 6, 'jul': 7, 'july': 7,
  'aug': 8, 'august': 8, 'sep': 9, 'sept': 9, 'september': 9, 'oct': 10,
  'october': 10, 'nov': 11, 'november': 11, 'dec': 12, 'december': 12,
};

int? _weekday(String w) => _weekdays[w];

/// A day-of-month token: "30", "30th", "3rd", "1st". Returns 1..31 or null.
int? _dayOfMonth(String w) {
  final m = RegExp(r'^(\d{1,2})(st|nd|rd|th)?$').firstMatch(w);
  if (m == null) return null;
  final d = int.parse(m.group(1)!);
  return (d >= 1 && d <= 31) ? d : null;
}

/// Recognise a calendar date — "30 aug", "aug 30", "august 30th",
/// "30 august 2027" — in either order, with an optional 4-digit year. When the
/// year is absent it resolves to the NEXT occurrence: this year if still ahead
/// of [now], otherwise next year (so "30 aug" said on 31 Aug means next year).
///
/// Returns the date and marks the month/day/year tokens consumed, or null when
/// no month+day pair is present. An impossible day (30 Feb) is rejected rather
/// than rolled over.
DateTime? _findCalendarDate(List<String> lower, List<bool> consumed, DateTime now) {
  for (var i = 0; i < lower.length; i++) {
    final month = _months[lower[i]];
    if (month == null) continue;

    // The day sits immediately before or after the month name.
    int? day;
    int dayIdx = -1;
    if (i + 1 < lower.length && _dayOfMonth(lower[i + 1]) != null) {
      day = _dayOfMonth(lower[i + 1]);
      dayIdx = i + 1;
    } else if (i - 1 >= 0 && _dayOfMonth(lower[i - 1]) != null) {
      day = _dayOfMonth(lower[i - 1]);
      dayIdx = i - 1;
    }
    if (day == null) continue;

    // Optional 4-digit year adjacent to the month/day cluster.
    int? year;
    int yearIdx = -1;
    final lo = i < dayIdx ? i : dayIdx;
    final hi = i > dayIdx ? i : dayIdx;
    for (final cand in [hi + 1, lo - 1]) {
      if (cand >= 0 && cand < lower.length) {
        final y = int.tryParse(lower[cand]);
        if (y != null && y >= 2000 && y <= 2100) {
          year = y;
          yearIdx = cand;
          break;
        }
      }
    }

    final resolvedYear = year ?? now.year;
    final candidate = DateTime(resolvedYear, month, day);
    // Reject an overflowed day (e.g. 30 Feb → 1/2 Mar).
    if (candidate.month != month || candidate.day != day) continue;

    final date = (year == null && candidate.isBefore(_dateOnly(now)))
        ? DateTime(resolvedYear + 1, month, day)
        : candidate;

    consumed[i] = true;
    consumed[dayIdx] = true;
    if (yearIdx >= 0) consumed[yearIdx] = true;
    return date;
  }
  return null;
}

/// A single clock hour, spelled or digit ("seven" or "7").
int? _clockNumber(String w) {
  final d = int.tryParse(w);
  if (d != null) return d;
  return _ones[w];
}

bool _isNumberWord(String w) {
  if (RegExp(r'^\d+(?:\.\d+)?$').hasMatch(w)) return true;
  return _ones.containsKey(w) ||
      _tens.containsKey(w) ||
      w == 'a' ||
      w == 'an' ||
      w == 'half' ||
      w == 'quarter' ||
      w == 'and';
}

/// Turn a small English number phrase into a value: "thirty" → 30,
/// "twenty five" → 25, "a"/"an" → 1, "half" → 0.5, "one and a half" → 1.5.
double? _phraseToNumber(List<String> words) {
  final w = words.where((x) => x != 'and').toList();
  if (w.isEmpty) return null;
  if (w.length == 1) {
    final d = double.tryParse(w.first);
    if (d != null) return d;
    if (w.first == 'a' || w.first == 'an') return 1;
    if (w.first == 'half') return 0.5;
    if (w.first == 'quarter') return 0.25;
    if (_ones.containsKey(w.first)) return _ones[w.first]!.toDouble();
    if (_tens.containsKey(w.first)) return _tens[w.first]!.toDouble();
    return null;
  }
  // Multi-word: tens+ones ("twenty five"), or "<n> and a half/quarter".
  var total = 0.0;
  var matched = false;
  var frac = 0.0;
  for (var i = 0; i < w.length; i++) {
    final x = w[i];
    if (_tens.containsKey(x)) {
      total += _tens[x]!;
      matched = true;
    } else if (_ones.containsKey(x)) {
      total += _ones[x]!;
      matched = true;
    } else if (x == 'a' || x == 'an') {
      // "a"/"an" before "half"/"quarter" is the article; alone it is 1.
      if (i + 1 < w.length && (w[i + 1] == 'half' || w[i + 1] == 'quarter')) {
        continue;
      }
      total += 1;
      matched = true;
    } else if (x == 'half') {
      frac = 0.5;
      matched = true;
    } else if (x == 'quarter') {
      frac = 0.25;
      matched = true;
    } else {
      final d = double.tryParse(x);
      if (d != null) {
        total += d;
        matched = true;
      }
    }
  }
  return matched ? total + frac : null;
}

// ── String helpers ───────────────────────────────────────────────────────────

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _collapseSpaces(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Strip leading/trailing punctuation from a token for MATCHING, keeping
/// apostrophes ("o'clock") and internal separators of times ("7:30", "7am").
String _stripPunct(String s) =>
    s.replaceAll(RegExp(r"^[^\w']+|[^\w':.]+$"), '');

const _fillerWords = {
  'at', 'on', 'for', 'set', 'a', 'an', 'the', 'alarm', 'reminder', 'remind',
  'me', 'to', 'call', 'it', 'please', 'and',
};

/// Drop connector/filler words from the EDGES of the title only — an interior
/// "the" in "clean the kitchen" is kept; a leading "set an alarm for" is not.
String _trimFiller(List<String> tokens) {
  var start = 0;
  var end = tokens.length;
  while (start < end && _fillerWords.contains(_stripPunct(tokens[start].toLowerCase()))) {
    start++;
  }
  while (end > start && _fillerWords.contains(_stripPunct(tokens[end - 1].toLowerCase()))) {
    end--;
  }
  return tokens.sublist(start, end).join(' ').trim();
}
