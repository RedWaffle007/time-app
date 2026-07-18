import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/timezone/tz_resolver.dart';
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

    return Scaffold(
      appBar: AppBar(title: const Text('My Schedule')),
      body: itemsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (items) {
          final approved = items
              .where((i) => i.status == ScheduleItemStatus.approved)
              .toList()
            ..sort((a, b) => a.scheduledInstantUtc.compareTo(b.scheduledInstantUtc));

          if (approved.isEmpty) {
            return const Center(child: Text('No approved items yet.'));
          }
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outcome = item.outcome;

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
            Text(formatInZone(item.scheduledInstantUtc, item.timezone)),
            const SizedBox(height: 12),
            if (outcome == null)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => _skip(context, ref),
                    child: const Text('Skip'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => ref
                        .read(scheduleRepositoryProvider)
                        .markDone(item.targetUid, item.id),
                    child: const Text('Done'),
                  ),
                ],
              )
            else
              _outcomeChip(outcome),
          ],
        ),
      ),
    );
  }

  Widget _outcomeChip(ScheduleOutcome outcome) {
    if (outcome.result == OutcomeResult.done) {
      return const Chip(
        avatar: Icon(Icons.check, color: Colors.green),
        label: Text('Done'),
      );
    }
    return Chip(
      avatar: const Icon(Icons.skip_next, color: Colors.orange),
      label: Text(outcome.skipReason == null
          ? 'Skipped'
          : 'Skipped — ${outcome.skipReason}'),
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
    }
  }
}
