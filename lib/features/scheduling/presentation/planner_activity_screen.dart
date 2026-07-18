import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/timezone/tz_resolver.dart';
import '../../auth/application/auth_providers.dart';
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
      appBar: AppBar(title: const Text('Activity')),
      body: itemsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (items) {
          if (items.isEmpty) {
            return const Center(child: Text('You haven\'t planned anything yet.'));
          }
          final sorted = [...items]
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
            Text('for $targetName · ${formatInZone(item.scheduledInstantUtc, item.timezone)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ..._outcomeLine(),
          ],
        ),
      ),
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
