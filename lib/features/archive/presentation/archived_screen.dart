import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/collapsible_day_groups.dart';
import '../../auth/application/auth_providers.dart';
import '../../calendar/application/calendar_grouping.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../application/archive_providers.dart';

/// Everything this user has hidden from their own views, and the one place to
/// put it back.
///
/// **One shared Archived screen, not one per tab.** A user archives *items*, not
/// items-as-target and items-as-planner; splitting the view would make them
/// remember which hat they were wearing when they hid something.
///
/// Nothing here is deleted and nothing here is private to this user's own
/// account: the other party's view is unaffected and was never told. That is
/// what makes this honest, and the subtitle says so out loud rather than leaving
/// the user to infer it.
class ArchivedScreen extends ConsumerWidget {
  const ArchivedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(archivedItemsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Archived')),
      body: AsyncView<List<ScheduleItem>>(
        value: itemsAsync,
        onRetry: () {
          ref.invalidate(allItemsAsTargetProvider);
          ref.invalidate(allItemsAsPlannerProvider);
          ref.invalidate(archivedIdsStreamProvider);
        },
        isEmpty: (items) => items.isEmpty,
        emptyIcon: AppIcons.emptyArchive,
        emptyMessage:
            "You haven't archived anything.\n"
            'Archiving hides a finished item from your own views — it never '
            'changes the record or what anyone else sees.',
        builder: (context, items) {
          final groups = _grouped(context, items);
          return CollapsibleDayGroups(
            // Full-screen route (no in-app bottom bar): clear the system nav.
            padding: Space.screenListSafe(context),
            // Preserve an immediately-visible single-month archive. As soon as
            // a second calendar month appears, month buckets become the
            // navigation and start collapsed.
            initiallyExpandedKeys:
                !CollapsibleDayGroups.usesMonthGrouping(groups)
                ? {for (final group in groups) group.key}
                : const {},
            groups: groups,
          );
        },
      ),
    );
  }

  List<DayGroupData> _grouped(BuildContext context, List<ScheduleItem> items) {
    final byDay = <String, List<ScheduleItem>>{};
    final dateFor = <String, DateTime>{};
    for (final item in items) {
      final date = calendarDayFor(item);
      final key = dayKeyOf(date);
      dateFor[key] = date;
      byDay.putIfAbsent(key, () => []).add(item);
    }
    return [
      for (final entry in byDay.entries)
        DayGroupData(
          key: entry.key,
          date: dateFor[entry.key]!,
          label: formatWallDate(context, dateFor[entry.key]!),
          itemCount: entry.value.length,
          itemBuilder: (_, index) => _ArchivedCard(item: entry.value[index]),
        ),
    ];
  }
}

class _ArchivedCard extends ConsumerWidget {
  const _ArchivedCard({required this.item});

  final ScheduleItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(currentUidProvider);
    // Whose item this was, from this user's side. A planner archiving their own
    // Activity row needs to know which target it belonged to; a target archiving
    // their own schedule row does not need to be told it was theirs.
    final isMine = item.targetUid == uid;
    final otherName =
        ref
            .watch(
              profileByUidProvider(isMine ? item.createdByUid : item.targetUid),
            )
            .value
            ?.name ??
        'someone';

    return Card(
      child: Padding(
        padding: Space.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(item.title, style: context.text.titleMedium),
                ),
                const SizedBox(width: Space.sm),
                // Same one-badge rule as everywhere else: an outcome replaces
                // the approval status, because "Done" implies "Approved".
                if (item.outcome case final o?)
                  StatusBadge.outcome(o.result, context)
                else
                  StatusBadge.status(item.status, context),
              ],
            ),
            const SizedBox(height: Space.xs),
            Text(
              [
                if (item.createdByUid == item.targetUid)
                  'yours'
                else if (isMine)
                  'from $otherName'
                else
                  'for $otherName',
                formatInstant(context, item.scheduledInstantUtc, item.timezone),
              ].join(' · '),
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            ..._reasonLine(context),
            // Only a MANUAL archive is reversible. A rejected or withdrawn item
            // is auto-hidden, and un-hiding it would put back exactly the
            // clutter that rejecting was the act of clearing — so those rows are
            // read-only here. This screen is where their record stays reachable,
            // which is why they are listed at all.
            if (item.isManuallyArchivable) ...[
              const SizedBox(height: Space.xs),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _unarchive(ref, uid),
                  icon: const Icon(AppIcons.unarchive, size: Sizes.inlineIcon),
                  label: const Text('Unarchive'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The reason the target gave, when they gave one.
  ///
  /// Load-bearing here in a way it is not elsewhere: a rejected item is
  /// auto-hidden from the planner's Activity feed the moment it is rejected, so
  /// **this screen is the only place a rejection reason remains readable.**
  /// Dropping it would turn "a rejection is never a silent disappearance" into
  /// exactly that.
  List<Widget> _reasonLine(BuildContext context) {
    final reason = switch (item) {
      ScheduleItem(
        status: ScheduleItemStatus.rejected,
        :final rejectionReason?,
      ) =>
        'Reason: $rejectionReason',
      ScheduleItem(outcome: ScheduleOutcome(:final skipReason?)) =>
        'Reason: $skipReason',
      _ => null,
    };
    if (reason == null) return const [];
    return [
      const SizedBox(height: Space.xs),
      Text(
        reason,
        style: context.text.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
    ];
  }

  /// No confirmation: unarchiving is additive and instantly reversible by
  /// archiving again. Confirming it would imply a weight it does not have.
  Future<void> _unarchive(WidgetRef ref, String? uid) async {
    if (uid == null) return;
    await ref.read(archiveRepositoryProvider).unarchive(uid, item.id);
  }
}
