import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/collapsible_day_groups.dart';
import '../../auth/application/auth_providers.dart';
import '../application/time_tracking_providers.dart';
import '../domain/tracked_entry.dart';
import 'log_time_sheet.dart';

/// **The Track pillar** (migration slice S1) — personal, manual time-tracking's
/// first real home. Free-form logging that owes nothing to planning, plus the
/// history: tap to edit, swipe to delete.
///
/// Reached for now through a TEMPORARY account-popup entry (the temporary-door
/// strategy); it becomes a bottom-bar pillar at the S5 cutover. Nothing here
/// references the schedule tree — the only bridge from planning is the optional
/// `sourceItemId` carried on Done-hook entries, which this screen shows but
/// never depends on.
class TrackScreen extends ConsumerWidget {
  const TrackScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(myTrackedEntriesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Track')),
      // The always-present create affordance for Track — a bottom-right FAB,
      // above the system nav bar (inner Scaffold clears the shell's bottom bar).
      // The manual, WhatsApp-style "＋" counterpart to the centre voice ⊕. Its
      // own heroTag so it never collides with the shell's voice FAB.
      floatingActionButton: FloatingActionButton(
        heroTag: 'trackLogFab',
        tooltip: 'Log item',
        onPressed: () => showLogTimeSheet(context, ref),
        child: const Icon(AppIcons.add),
      ),
      body: AsyncView<List<TrackedEntry>>(
        value: entriesAsync,
        onRetry: () => ref.invalidate(myTrackedEntriesProvider),
        isEmpty: (entries) => entries.isEmpty,
        emptyIcon: AppIcons.emptyTrack,
        emptyMessage: "You haven't logged any time yet.\n"
            'Tap + to log time you spent on anything — it need not be a plan.',
        builder: (context, entries) => CollapsibleDayGroups(
          padding: Space.screenList,
          initiallyExpandedKeys: {_todayKey()},
          groups: _grouped(context, entries),
        ),
      ),
    );
  }

  /// Fold the (already logDate-desc) entries into collapsible day groups. The
  /// repo sorts by `logDate` descending, so a new group starts whenever the day
  /// changes while walking the list — most-recent day first.
  List<DayGroupData> _grouped(BuildContext context, List<TrackedEntry> entries) {
    final groups = <DayGroupData>[];
    for (final entry in entries) {
      if (groups.isEmpty || groups.last.key != entry.logDate) {
        groups.add(DayGroupData(
          key: entry.logDate,
          label: _dayLabel(context, entry.logDate),
          children: [_EntryCard(entry: entry)],
        ));
      } else {
        groups.last.children.add(_EntryCard(entry: entry));
      }
    }
    return groups;
  }

  /// Device-local today as a `YYYY-MM-DD` key, to match `TrackedEntry.logDate`
  /// (the day expanded by default).
  static String _todayKey() => dayKeyOf(DateTime.now());

  /// A `YYYY-MM-DD` log date as a localized wall date. Relative labels
  /// ("Today"/"Yesterday") wait on the relative-time helper that does not exist
  /// yet (CLAUDE.md) — a plain localized date is correct in the meantime.
  static String _dayLabel(BuildContext context, String logDate) {
    final parts = logDate.split('-');
    if (parts.length != 3) return logDate;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return logDate;
    return formatWallDate(context, DateTime(y, m, d));
  }
}

class _EntryCard extends ConsumerWidget {
  const _EntryCard({required this.entry});

  final TrackedEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.colors;

    // A logged entry can be deleted by its owner at will — a swipe, with an
    // undo. Red is legitimate here: delete is destructive (§2.5).
    return Dismissible(
      key: ValueKey(entry.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: Space.xl),
        decoration: BoxDecoration(
          color: cs.errorContainer,
          borderRadius: Radii.md,
        ),
        child: Icon(AppIcons.delete, color: cs.onErrorContainer),
      ),
      onDismissed: (_) => _delete(context, ref),
      child: Card(
        child: ListTile(
          leading: Icon(AppIcons.duration, color: cs.onSurfaceVariant),
          title: Text(entry.taskName, style: context.text.titleMedium),
          subtitle: Text(_subtitle(context)),
          trailing: const Icon(AppIcons.edit),
          onTap: () => showLogTimeSheet(context, ref, existing: entry),
        ),
      ),
    );
  }

  /// Duration is the headline fact; the optional range is a quiet suffix. The
  /// end is derived from start + duration, so it can wrap past midnight — marked
  /// `(+1d)` so an earlier-looking end never reads as a mistake.
  String _subtitle(BuildContext context) {
    final duration = formatDurationMinutes(context, entry.durationMinutes);
    if (!entry.hasRange) return duration;
    final start = _asTime(entry.startLocal!);
    final end = _asTime(entry.endLocal!);
    final startLabel = formatTimeOfDay(context, start);
    final endLabel = formatTimeOfDay(context, end);
    final wraps = _mins(end) <= _mins(start) ? ' (+1d)' : '';
    return '$duration · $startLabel–$endLabel$wraps';
  }

  static TimeOfDay _asTime(String hhmm) {
    final parts = hhmm.split(':');
    final h = int.tryParse(parts.first) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return TimeOfDay(hour: h, minute: m);
  }

  static int _mins(TimeOfDay t) => t.hour * 60 + t.minute;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final uid = ref.read(currentUidProvider);
    if (uid == null) return;
    final repo = ref.read(trackedTimeRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    await repo.delete(uid, entry.id);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Entry deleted'),
        action: SnackBarAction(
          label: 'Undo',
          // Re-log recreates the entry (a new id — a personal log has no stable
          // identity to preserve). uid is captured, so if the account has since
          // changed the owner-only rules simply reject it; no cross-account write.
          onPressed: () => repo.log(
            uid,
            TrackedEntry(
              id: '',
              taskName: entry.taskName,
              durationMinutes: entry.durationMinutes,
              logDate: entry.logDate,
              startLocal: entry.startLocal,
              endLocal: entry.endLocal,
              sourceItemId: entry.sourceItemId,
            ),
          ),
        ),
      ),
    );
  }
}
