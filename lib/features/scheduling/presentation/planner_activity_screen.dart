import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/widgets/async_view.dart';
import '../../../routing/app_router.dart';
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
        icon: const Icon(Icons.add),
        label: const Text('Plan an item'),
      ),
      body: AsyncView<List<ScheduleItem>>(
        value: itemsAsync,
        onRetry: () => ref.invalidate(myItemsAsPlannerProvider),
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

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(item.title,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                ),
                _statusBadge(),
              ],
            ),
            const SizedBox(height: 4),
            // Always name the zone: this time is in the TARGET's local time, not
            // the planner's — a bare "09:00" here is the most misleading thing a
            // planner could see.
            Text(
              'for $targetName · '
              '${formatInstant(context, item.scheduledInstantUtc, item.timezone)} '
              '(${item.timezone}, their local time)',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            ..._outcomeLine(),
            // A plan can be withdrawn only while it's still pending — once the
            // target has decided, it's theirs to keep or reject.
            if (item.status == ScheduleItemStatus.pending) ...[
              const SizedBox(height: 4),
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
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Withdraw')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(scheduleRepositoryProvider).withdraw(item.targetUid, item.id);
    await ref.read(notificationEventNotifierProvider).notify(
          event: NotifyEvent.withdrawn,
          targetUid: item.targetUid,
          itemId: item.id,
        );
  }

  /// The approval-status badge. Rejection is shown explicitly, never hidden.
  Widget _statusBadge() {
    final (String label, Color color) = switch (item.status) {
      ScheduleItemStatus.pending => ('Pending', Colors.blueGrey),
      ScheduleItemStatus.approved => ('Approved', Colors.green),
      ScheduleItemStatus.rejected => ('Rejected', Colors.red),
      ScheduleItemStatus.cancelled => ('Cancelled', Colors.grey),
      ScheduleItemStatus.withdrawn => ('Withdrawn', Colors.orange),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    );
  }

  /// Extra lines for the outcome (Done/Skip) once the target acts.
  List<Widget> _outcomeLine() {
    final o = item.outcome;
    if (o != null) {
      final text = o.result == OutcomeResult.done
          ? '✅ Marked done'
          : '⏭️ Skipped${o.skipReason != null ? ' — ${o.skipReason}' : ''}';
      return [
        const SizedBox(height: 6),
        Text(text, style: const TextStyle(fontWeight: FontWeight.w500)),
      ];
    }
    // Surface the rejection reason so a rejection is never a silent disappearance.
    if (item.status == ScheduleItemStatus.rejected && item.rejectionReason != null) {
      return [
        const SizedBox(height: 6),
        Text('Reason: ${item.rejectionReason}',
            style: const TextStyle(fontStyle: FontStyle.italic)),
      ];
    }
    return const [];
  }
}
