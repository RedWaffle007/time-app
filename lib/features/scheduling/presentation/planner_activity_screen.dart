import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../core/widgets/async_view.dart';
import '../../../routing/app_router.dart';
import '../../archive/presentation/archive_menu_button.dart';
import '../../auth/application/auth_providers.dart';
import '../../home/presentation/account_button.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../application/schedule_providers.dart';
import '../domain/schedule_item.dart';

/// The planner's view of everything they created — updates LIVE as the target
/// approves/rejects and marks Done/Skip (Option B: no push, just a Firestore
/// listener). This is where the loop closes for the planner.
class PlannerActivityScreen extends ConsumerWidget {
  const PlannerActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(myItemsAsPlannerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: const [AccountButton()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // Unique tag — this tab is mounted alongside GroupsScreen's FAB inside
        // HomeShell's IndexedStack, so the default shared FAB hero tag collides.
        heroTag: 'activityFab',
        onPressed: () => context.push(Routes.scheduleBuilder),
        icon: const Icon(AppIcons.add),
        label: const Text('Plan an item'),
      ),
      body: AsyncView<List<ScheduleItem>>(
        value: itemsAsync,
        // Retry the SOURCE stream. `myItemsAsPlannerProvider` is a derived
        // Provider; invalidating it would recompute the filter without ever
        // reconnecting the Firestore listener that actually failed.
        onRetry: () => ref.invalidate(allItemsAsPlannerProvider),
        // Self-planned items (creator == target) live in My Schedule, not here —
        // Activity is about people you plan FOR.
        isEmpty: (items) =>
            items.every((i) => i.createdByUid == i.targetUid),
        emptyMessage: "You haven't planned anything for anyone yet.",
        builder: (context, items) {
          final sorted = items
              .where((i) => i.createdByUid != i.targetUid)
              .toList()
            ..sort((a, b) => b.scheduledInstantUtc.compareTo(a.scheduledInstantUtc));
          return ListView(
            children: [for (final item in sorted) _ActivityCard(item: item)],
          );
        },
      ),
    );
  }
}

class _ActivityCard extends ConsumerWidget {
  const _ActivityCard({required this.item});

  final ScheduleItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targetName =
        ref.watch(profileByUidProvider(item.targetUid)).value?.name ?? 'target';

    // Card margin, padding, radius, border and elevation all come from
    // CardTheme (UI-RULES.md §6.1) — a bare Card would inherit Material's
    // default shadow, which the flat-by-default rule forbids.
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
                // ONE badge. Once an outcome exists it replaces the approval
                // status, because "Done" strictly implies "Approved" — showing
                // both states the same fact twice.
                if (item.outcome case final o?)
                  StatusBadge.outcome(o.result, context)
                else
                  StatusBadge.status(item.status, context),
                // Done or skipped — the planner may clear it from their own
                // feed when they're ready, from the card overflow. Rejected and
                // withdrawn rows never render here at all: they are auto-hidden
                // the moment their status is set, so this feed no longer
                // accumulates them.
                if (item.isManuallyArchivable) ArchiveMenuButton(item: item),
              ],
            ),
            const SizedBox(height: Space.xs),
            // Always name the zone: this time is in the TARGET's local time, not
            // the planner's — a bare "09:00" here is the most misleading thing a
            // planner could see.
            Text(
              'for $targetName · '
              '${formatInstant(context, item.scheduledInstantUtc, item.timezone)} '
              '(${item.timezone}, their local time)',
              // bodySmall, not labelSmall: this reads as a sentence even though
              // it carries metadata (UI-RULES.md §3, prose-wins tiebreaker).
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            ..._reasonLine(context),
            // A plan can be withdrawn only while it's still pending — once the
            // target has decided, it's theirs to keep or reject.
            if (item.status == ScheduleItemStatus.pending) ...[
              const SizedBox(height: Space.xs),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _withdraw(context, ref),
                  child: const Text('Withdraw'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Withdraw a still-pending plan, then notify the target it's gone. The write
  /// is the source of truth; the push is additive (a failed push never blocks
  /// the withdrawal).
  Future<void> _withdraw(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Withdraw this plan?'),
        content: const Text(
          "It will be removed from the target's pending queue before they "
          'decide on it.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          // Destructive — one of the rationed uses of red (UI-RULES.md §2.5).
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ctx.colors.error,
              foregroundColor: ctx.colors.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Withdraw'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(scheduleRepositoryProvider)
        // `item:` frees the slot lock this plan was holding.
        .withdraw(item.targetUid, item.id, item: item);
    await ref.read(notificationEventNotifierProvider).notify(
          event: NotifyEvent.withdrawn,
          targetUid: item.targetUid,
          itemId: item.id,
        );
  }

  /// The reason line, when the target gave one.
  ///
  /// The outcome itself is carried by the badge in the header — this is only the
  /// prose. Quoted user content is distinguished by `onSurfaceVariant` colour,
  /// never italics (UI-RULES.md §3).
  ///
  /// In practice only the skip arm is reachable from this screen now: rejected
  /// items are auto-hidden before they can render here, and their reason is
  /// shown on the Archived screen instead. The rejected arm is kept rather than
  /// deleted because it is the correct rendering for the state, and narrowing
  /// the auto-hide rule would need it back immediately.
  List<Widget> _reasonLine(BuildContext context) {
    final reason = switch (item) {
      ScheduleItem(status: ScheduleItemStatus.rejected, :final rejectionReason?) =>
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
        style:
            context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
      ),
    ];
  }
}
