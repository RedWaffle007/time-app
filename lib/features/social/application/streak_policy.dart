import 'package:timezone/timezone.dart' as tz;

import '../domain/profile_stat.dart';

/// The current and best run under the **humane streak** rule (item 24b,
/// user-decided 2026-09-27 — DECISIONS.md "Stats review").
class Streaks {
  const Streaks({required this.current, required this.best});

  static const zero = Streaks(current: 0, best: 0);

  final int current;
  final int best;
}

/// Streaks over the user's plans as TARGET, counted in days of their home
/// timezone [timezone].
///
/// Each day is classified by the plans scheduled on it:
///
/// * **breaks** — any plan that day was [StatItem.isMissed] (nobody answered);
/// * **extends** — at least one Done and no Missed;
/// * **neutral** — no plans, or only deliberate skips / unsettled plans.
///
/// Neutral days neither extend nor break, so a rest day, a travel day or a day
/// nobody planned anything never costs a streak. Today's still-unanswered
/// plans are not Missed yet, so today can never break the run early.
///
/// Days are the HOME zone's calendar days (a streak breaks at the midnight the
/// person lived), computed as an ordinal that is immune to DST (a 23- or
/// 25-hour local day is still one day). An unknown zone yields zero rather than
/// throwing inside a stats pass.
Streaks computeStreaks(List<StatItem> itemsAsTarget, String timezone) {
  if (itemsAsTarget.isEmpty) return Streaks.zero;

  final tz.Location location;
  try {
    location = tz.getLocation(timezone);
  } catch (_) {
    return Streaks.zero;
  }

  int dayNumber(DateTime utc) {
    final local = tz.TZDateTime.from(utc, location);
    return DateTime.utc(
      local.year,
      local.month,
      local.day,
    ).difference(DateTime.utc(1970, 1, 1)).inDays;
  }

  final doneDays = <int>{};
  final missedDays = <int>{};
  for (final item in itemsAsTarget) {
    if (item.isCancelled) continue;
    if (item.isMissed) {
      missedDays.add(dayNumber(item.instantUtc));
    } else if (item.isDone) {
      doneDays.add(dayNumber(item.instantUtc));
    }
  }

  // Only eventful days matter; neutral days are simply absent.
  final eventful = {...doneDays, ...missedDays}.toList()..sort();

  var best = 0;
  var run = 0;
  for (final day in eventful) {
    if (missedDays.contains(day)) {
      run = 0;
    } else {
      run++;
      if (run > best) best = run;
    }
  }
  // After the loop `run` is the streak ending at the most recent eventful day,
  // which — neutral days being free — is the current streak.
  return Streaks(current: run, best: best);
}
