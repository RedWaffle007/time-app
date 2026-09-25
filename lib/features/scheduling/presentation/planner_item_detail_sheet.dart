import 'package:flutter/material.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/planner_item_timeline.dart';
import '../domain/schedule_item.dart';

/// The item's status timeline. Opened from Activity (planner side) and from
/// My Schedule / History (target side); [contextLine] replaces the planner's
/// "For [targetName]" line on the target side.
Future<void> showPlannerItemDetailSheet(
  BuildContext context, {
  required ScheduleItem item,
  required String targetName,
  String? contextLine,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PlannerItemDetail(
      item: item,
      targetName: targetName,
      contextLine: contextLine,
    ),
  );
}

class _PlannerItemDetail extends StatelessWidget {
  const _PlannerItemDetail({
    required this.item,
    required this.targetName,
    this.contextLine,
  });

  final ScheduleItem item;
  final String targetName;
  final String? contextLine;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: Space.screenForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.title, style: context.text.headlineSmall),
            const SizedBox(height: Space.xs),
            Text(
              contextLine ?? 'For $targetName · ${item.timezone}',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            if (item.durationMinutes > 0) ...[
              const SizedBox(height: Space.xs),
              Text(
                formatDurationMinutes(context, item.durationMinutes),
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
            if (item.note case final note? when note.trim().isNotEmpty) ...[
              const SizedBox(height: Space.md),
              Text(note.trim(), style: context.text.bodyMedium),
            ],
            const SizedBox(height: Space.xl),
            Text('Timeline', style: context.text.titleLarge),
            const SizedBox(height: Space.sm),
            for (final event in plannerTimelineFor(item))
              _TimelineRow(event: event, timezone: item.timezone),
          ],
        ),
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.event, required this.timezone});

  final PlannerTimelineEvent event;
  final String timezone;

  @override
  Widget build(BuildContext context) {
    final pending = event.isPending;
    return Semantics(
      excludeSemantics: true,
      label: pending
          ? 'Outcome pending, waiting for target'
          : '${_label(event.kind)}, ${_time(context)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _icon(event.kind),
              size: Sizes.inlineIcon,
              color: pending
                  ? context.attention
                  : context.colors.onSurfaceVariant,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_label(event.kind), style: context.text.titleMedium),
                  const SizedBox(height: Space.xs),
                  Text(
                    pending ? 'Waiting for target' : _time(context),
                    style: context.text.bodySmall?.copyWith(
                      color: pending
                          ? context.attention
                          : context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _time(BuildContext context) => event.atUtc == null
      ? 'Time unavailable'
      : formatInstant(context, event.atUtc!, timezone);
}

String _label(PlannerTimelineEventKind kind) => switch (kind) {
  PlannerTimelineEventKind.scheduled => 'Scheduled',
  PlannerTimelineEventKind.rang => 'Rang',
  PlannerTimelineEventKind.dismissed => 'Dismissed',
  PlannerTimelineEventKind.unavailable => 'User unavailable at alarm time',
  PlannerTimelineEventKind.done => 'Done',
  PlannerTimelineEventKind.skipped => 'Skipped',
  PlannerTimelineEventKind.pendingOutcome => 'Outcome pending',
};

IconData _icon(PlannerTimelineEventKind kind) => switch (kind) {
  PlannerTimelineEventKind.scheduled => AppIcons.date,
  PlannerTimelineEventKind.rang => AppIcons.reminders,
  PlannerTimelineEventKind.dismissed => AppIcons.close,
  PlannerTimelineEventKind.unavailable => AppIcons.skipped,
  PlannerTimelineEventKind.done => AppIcons.done,
  PlannerTimelineEventKind.skipped => AppIcons.skipped,
  PlannerTimelineEventKind.pendingOutcome => AppIcons.pending,
};
