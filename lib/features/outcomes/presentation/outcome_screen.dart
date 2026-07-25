import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../core/widgets/async_view.dart';
import '../../../routing/app_router.dart';
import '../../home/presentation/account_button.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';

/// The target's approved items — where they mark Done or Skip.
///
/// NOTE: still contains NO alarm logic. Without alarms, this is simply the list
/// of what the target agreed to, with completion controls. Alarms (which would
/// deep-link straight to one item) come later, when directed.
class OutcomeScreen extends ConsumerWidget {
  const OutcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(myItemsAsTargetProvider);
    final pendingCount = itemsAsync.value
            ?.where((i) => i.status == ScheduleItemStatus.pending)
            .length ??
        0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Schedule'),
        actions: [
          IconButton(
            tooltip: 'Pending approvals',
            icon: Badge(
              isLabelVisible: pendingCount > 0,
              label: Text('$pendingCount'),
              child: const Icon(Icons.inbox_outlined),
            ),
            onPressed: () => context.push(Routes.approvals),
          ),
          const AccountButton(),
        ],
      ),
      body: AsyncView<List<ScheduleItem>>(
        value: itemsAsync,
        onRetry: () => ref.invalidate(myItemsAsTargetProvider),
        isEmpty: (items) =>
            !items.any((i) => i.status == ScheduleItemStatus.approved),
        emptyMessage: 'No approved items yet.',
        builder: (context, items) {
          final approved = items
              .where((i) => i.status == ScheduleItemStatus.approved)
              .toList()
            ..sort((a, b) => a.scheduledInstantUtc.compareTo(b.scheduledInstantUtc));
          return ListView(
            children: [for (final item in approved) _OutcomeCard(item: item)],
          );
        },
      ),
    );
  }
}

class _OutcomeCard extends ConsumerWidget {
  const _OutcomeCard({required this.item});

  final ScheduleItem item;

  /// A self-planned item has the same person as creator and target — no planner
  /// on the other end to notify.
  bool get _isSelfPlanned => item.createdByUid == item.targetUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outcome = item.outcome;

    return Card(
      child: Padding(
        padding: Space.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.title, style: context.text.titleMedium),
            const SizedBox(height: Space.xs),
            Text(formatInstant(context, item.scheduledInstantUtc, item.timezone)),
            const SizedBox(height: Space.md),
            if (outcome == null)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Skipping is a legitimate outcome, so it gets the neutral
                  // secondary treatment — never red (UI-RULES.md §2.5).
                  OutlinedButton(
                    onPressed: () => _skip(context, ref),
                    child: const Text('Skip'),
                  ),
                  const SizedBox(width: Space.sm),
                  FilledButton(
                    onPressed: () => _markDone(ref),
                    child: const Text('Done'),
                  ),
                ],
              )
            else
              _outcomeLine(context, outcome),
          ],
        ),
      ),
    );
  }

  /// The recorded outcome. This used to be a second, private status→colour
  /// mapping that disagreed with the planner's view; both now read the one
  /// mapping in `status_style.dart` (UI-RULES.md §2.3).
  Widget _outcomeLine(BuildContext context, ScheduleOutcome outcome) {
    return Row(
      children: [
        StatusBadge.outcome(outcome.result, context),
        if (outcome.skipReason case final reason?) ...[
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              reason,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }

  /// Record completion, then fire the (best-effort) planner push. The write is
  /// the source of truth; the push is additive (see DECISIONS.md).
  Future<void> _markDone(WidgetRef ref) async {
    await ref.read(scheduleRepositoryProvider).markDone(item.targetUid, item.id);
    if (_isSelfPlanned) return; // no point notifying yourself
    await ref.read(notificationEventNotifierProvider).notify(
          event: NotifyEvent.outcome,
          targetUid: item.targetUid,
          itemId: item.id,
        );
  }

  Future<void> _skip(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Skip this?'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Reason (optional)',
            hintText: 'Your planner will see this',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Skip')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(scheduleRepositoryProvider).markSkipped(
            item.targetUid,
            item.id,
            reason: controller.text,
          );
      if (_isSelfPlanned) return; // no point notifying yourself
      await ref.read(notificationEventNotifierProvider).notify(
            event: NotifyEvent.outcome,
            targetUid: item.targetUid,
            itemId: item.id,
          );
    }
  }
}
