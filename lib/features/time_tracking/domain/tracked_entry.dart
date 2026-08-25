import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:timezone/timezone.dart' as tz;

/// The maximum minutes a single [TrackedEntry] may hold. Derived, not arbitrary:
/// every entry belongs to exactly one day, so one entry can never exceed a day's
/// worth. A log that transcends a day becomes N single-day entries (see
/// [apportionAcrossDays]) rather than one oversized or date-spanning row, so no
/// day-bucketed stat ever has to reason about "more than 24h in a day".
///
/// Mirrored in `firestore.rules` (`trackedTime.validEntry`) — both sides
/// together, per the codebase's cap-on-both-sides rule.
const int kMaxEntryMinutes = 1440;

/// A single manual time-tracking entry, stored at
/// `users/{uid}/trackedTime/{entryId}`.
///
/// A genuinely separate feature from planning. The only bridge to a plan is the
/// optional [sourceItemId] soft link, which is a self-note the owner writes and
/// is never verified against the schedule tree.
///
/// **Duration is authoritative and always whole minutes** — never fractional
/// hours. The optional time-of-day range is DERIVED from it: [startLocal] is
/// user-set, and [endLocal] is always `start + durationMinutes` (see
/// [deriveEndLocal]), so the two can never disagree. This supersedes the earlier
/// "range is independent display metadata" rule (DECISIONS.md 2026-08-25). A
/// range exists iff a start is set — both-or-neither, structurally.
class TrackedEntry {
  TrackedEntry({
    required this.id,
    required this.taskName,
    required this.durationMinutes,
    required this.logDate,
    this.startLocal,
    this.endLocal,
    this.sourceItemId,
    this.createdAt,
    this.updatedAt,
  })  : assert(durationMinutes >= 1 && durationMinutes <= kMaxEntryMinutes,
            'durationMinutes must be 1..$kMaxEntryMinutes (one day)'),
        assert((startLocal == null) == (endLocal == null),
            'the time-of-day range is both-or-neither');

  final String id;

  /// Free-form; the task need not correspond to any plan or alarm.
  final String taskName;

  /// Whole minutes, 1..[kMaxEntryMinutes]. The authoritative unit.
  final int durationMinutes;

  /// The one day this time is attributed to: `YYYY-MM-DD`, a wall date in the
  /// owner's home timezone at creation. Lexical order is chronological, so
  /// "today"/"this week"/streak queries are plain string ranges with no tz math.
  final String logDate;

  /// Optional range, wall-clock `HH:mm`, no offset. [startLocal] is user-set;
  /// [endLocal] is derived as `start + durationMinutes` ([deriveEndLocal]) and
  /// is never asked for. When `end <= start` the range wrapped past midnight —
  /// truthful, since duration is the source of truth for how long it was.
  final String? startLocal;
  final String? endLocal;

  /// Optional soft link to the plan a Done-hook entry came from. Present ONLY
  /// for Done-hook entries; absent for manual/voice. Recorded, never verified.
  final String? sourceItemId;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get hasRange => startLocal != null && endLocal != null;

  /// True when this entry originated from marking a plan Done.
  bool get isFromPlan => sourceItemId != null;

  /// The write payload. `createdAt`/`updatedAt` are stamped by the repository
  /// with a server timestamp, so they are not included here.
  Map<String, dynamic> toCreateMap() => {
        'taskName': taskName,
        'durationMinutes': durationMinutes,
        'logDate': logDate,
        if (startLocal != null) 'startLocal': startLocal,
        if (endLocal != null) 'endLocal': endLocal,
        if (sourceItemId != null) 'sourceItemId': sourceItemId,
      };

  factory TrackedEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return TrackedEntry(
      id: doc.id,
      taskName: (d['taskName'] ?? '') as String,
      durationMinutes: (d['durationMinutes'] as num?)?.toInt() ?? 1,
      logDate: (d['logDate'] ?? '') as String,
      startLocal: d['startLocal'] as String?,
      endLocal: d['endLocal'] as String?,
      sourceItemId: d['sourceItemId'] as String?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// The `YYYY-MM-DD` wall date, in [timezone], that a UTC [instant] falls on.
///
/// The one place a log date is derived. An unknown/empty zone falls back to the
/// instant's own UTC date rather than throwing — a wrong-by-offset date is
/// better than a lost entry, and the tracker never fires alarms off this.
String logDateFor(DateTime instant, String timezone) {
  tz.Location? location;
  try {
    location = tz.getLocation(timezone);
  } catch (_) {
    location = null;
  }
  final local =
      location == null ? instant.toUtc() : tz.TZDateTime.from(instant, location);
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

/// The end of a time-of-day range, derived as `startLocal + durationMinutes`.
///
/// [startLocal] is `HH:mm`. The result wraps modulo 24h, so a start plus a
/// duration that crosses midnight yields an end that is earlier on the clock
/// (e.g. `23:00` + 90 → `00:30`). That is correct: the range is a lens over the
/// authoritative [TrackedEntry.durationMinutes], not a second source of length.
/// A malformed start defaults its parts to 0 rather than throwing.
String deriveEndLocal(String startLocal, int durationMinutes) {
  final parts = startLocal.split(':');
  final h = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
  final m = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
  final end = (h * 60 + m + durationMinutes) % (24 * 60);
  return '${(end ~/ 60).toString().padLeft(2, '0')}:'
      '${(end % 60).toString().padLeft(2, '0')}';
}

/// One day's share of a multi-day log: a `logDate` and the minutes for it.
class DayShare {
  const DayShare(this.logDate, this.minutes);
  final String logDate;
  final int minutes;
}

/// Raised when a requested multi-day split cannot obey the one-day rule — e.g.
/// [totalMinutes] exceeds `days.length * kMaxEntryMinutes`, so it will not fit
/// however it is spread. Carries a message already written for the user.
class ApportionmentImpossible implements Exception {
  const ApportionmentImpossible(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Split [totalMinutes] as evenly as possible across [dates], producing one
/// [DayShare] per date, each in 1..[kMaxEntryMinutes] and summing exactly to
/// [totalMinutes].
///
/// A pure helper the future multi-day PROMPT UI can drive (the prompt lets the
/// user pick the days; this proposes a fair default apportionment the user can
/// then adjust). It exists now so the data model already assumes one-entry-per-
/// day and we never migrate a spanning row into per-day rows later.
///
/// The remainder is spread one minute at a time across the earliest days, so the
/// shares differ by at most one minute and always re-sum to the exact total.
List<DayShare> apportionAcrossDays(int totalMinutes, List<String> dates) {
  if (dates.isEmpty) {
    throw const ApportionmentImpossible('Pick at least one day to log against.');
  }
  if (totalMinutes < dates.length) {
    // Fewer minutes than days would force a 0-minute (invalid) share somewhere.
    throw ApportionmentImpossible(
      'That is too few minutes to spread across ${dates.length} days.',
    );
  }
  if (totalMinutes > dates.length * kMaxEntryMinutes) {
    throw ApportionmentImpossible(
      'That is more than ${dates.length} days can hold. Add more days.',
    );
  }
  final base = totalMinutes ~/ dates.length;
  var remainder = totalMinutes % dates.length;
  return [
    for (final date in dates)
      DayShare(date, base + (remainder-- > 0 ? 1 : 0)),
  ];
}
