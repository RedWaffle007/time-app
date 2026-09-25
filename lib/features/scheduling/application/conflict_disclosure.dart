import '../domain/schedule_item.dart';
import '../domain/slot.dart';

/// Privacy-minimal conflict information for one target.
///
/// The presentation layer gets no [ScheduleItem], title, note, status, creator,
/// or outcome. Once this boundary is crossed it is impossible for the warning
/// dialog to accidentally disclose schedule content while rendering a time.
class ConflictDisclosureGroup {
  const ConflictDisclosureGroup({
    required this.uid,
    required this.name,
    required this.timezone,
    required this.instantsUtc,
  });

  final String uid;
  final String name;
  final String timezone;
  final List<DateTime> instantsUtc;
}

/// Live, outcome-less pending/approved items on [localDay] in [timezone].
///
/// Reuses [blocksSlot], the existing live-item policy, instead of maintaining a
/// second definition of what counts. Results are unique and chronological: two
/// items at one instant produce one time disclosure, not item-count metadata.
List<DateTime> conflictInstantsForLocalDay({
  required DateTime localDay,
  required String timezone,
  required List<ScheduleItem> items,
}) {
  final (startUtc, endUtc) = localDayRangeUtc(localDay, timezone);
  final instants = <int, DateTime>{};
  for (final item in items) {
    final instant = item.scheduledInstantUtc.toUtc();
    if (blocksSlot(item) &&
        !instant.isBefore(startUtc) &&
        instant.isBefore(endUtc)) {
      instants[instant.microsecondsSinceEpoch] = instant;
    }
  }
  final result = instants.values.toList()..sort((a, b) => a.compareTo(b));
  return result;
}

/// Stable identity for what the popup reveals. Names are deliberately absent:
/// a rename does not make unchanged conflict information nag again.
String conflictDisclosureFingerprint({
  required DateTime localDay,
  required List<ConflictDisclosureGroup> groups,
  Iterable<String> errorUids = const [],
}) {
  final sortedGroups = [...groups]..sort((a, b) => a.uid.compareTo(b.uid));
  final sortedErrors = errorUids.toSet().toList()..sort();
  final day =
      '${localDay.year.toString().padLeft(4, '0')}-'
      '${localDay.month.toString().padLeft(2, '0')}-'
      '${localDay.day.toString().padLeft(2, '0')}';
  final buffer = StringBuffer(day);
  for (final group in sortedGroups) {
    final sortedInstants =
        group.instantsUtc
            .map((instant) => instant.toUtc().microsecondsSinceEpoch)
            .toList()
          ..sort();
    buffer
      ..write('|')
      ..write(group.uid)
      ..write('@')
      ..write(group.timezone)
      ..write(':')
      ..write(sortedInstants.join(','));
  }
  if (sortedErrors.isNotEmpty) {
    buffer
      ..write('|errors:')
      ..write(sortedErrors.join(','));
  }
  return buffer.toString();
}
