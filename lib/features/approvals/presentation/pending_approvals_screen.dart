import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/widgets/async_view.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';

/// The target's pending queue — approve or reject each item individually.
class PendingApprovalsScreen extends ConsumerWidget {
  const PendingApprovalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(myItemsAsTargetProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Pending Approvals')),
      body: AsyncView<List<ScheduleItem>>(
        value: itemsAsync,
        onRetry: () => ref.invalidate(myItemsAsTargetProvider),
        isEmpty: (items) =>
            !items.any((i) => i.status == ScheduleItemStatus.pending),
        emptyMessage: 'Nothing waiting for approval.',
        builder: (context, items) {
          final pending = items
              .where((i) => i.status == ScheduleItemStatus.pending)
              .toList()
            ..sort((a, b) => a.scheduledInstantUtc.compareTo(b.scheduledInstantUtc));
          return ListView(
            children: [for (final item in pending) _ApprovalCard(item: item)],
          );
        },
      ),
    );
  }
}

class _ApprovalCard extends ConsumerWidget {
  const _ApprovalCard({required this.item});

  final ScheduleItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plannerName =
        ref.watch(profileByUidProvider(item.createdByUid)).value?.name ?? 'Someone';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(formatInstant(context, item.scheduledInstantUtc, item.timezone)),
            Text('${item.timezone} · from $plannerName',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (item.note != null && item.note!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('“${item.note}”', style: const TextStyle(fontStyle: FontStyle.italic)),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _reject(context, ref),
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _approve(ref),
                  child: const Text('Approve'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Approve, then notify the planner. The write is the source of truth; the
  /// push is additive (a failed push never blocks the approval).
  Future<void> _approve(WidgetRef ref) async {
    await ref.read(scheduleRepositoryProvider).approve(item.targetUid, item.id);
    await ref.read(notificationEventNotifierProvider).notify(
          event: NotifyEvent.decided,
          targetUid: item.targetUid,
          itemId: item.id,
        );
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject this item?'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Reason (optional)',
            hintText: 'The planner will see this',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(scheduleRepositoryProvider).reject(
            item.targetUid,
            item.id,
            reason: controller.text,
          );
      await ref.read(notificationEventNotifierProvider).notify(
            event: NotifyEvent.decided,
            targetUid: item.targetUid,
            itemId: item.id,
          );
    }
  }
}
