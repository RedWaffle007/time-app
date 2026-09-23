import '../domain/schedule_item.dart';

enum PlannerTimelineEventKind {
  scheduled,
  rang,
  dismissed,
  done,
  skipped,
  pendingOutcome,
}

class PlannerTimelineEvent {
  const PlannerTimelineEvent({required this.kind, this.atUtc});

  final PlannerTimelineEventKind kind;
  final DateTime? atUtc;
  bool get isPending => kind == PlannerTimelineEventKind.pendingOutcome;
}

/// The planner sees reached facts only, plus one explicit final pending state.
/// Missing legacy timestamps remain reached with an unavailable time; they are
/// never fabricated from `updatedAt` or the scheduled instant.
List<PlannerTimelineEvent> plannerTimelineFor(ScheduleItem item) {
  final events = <PlannerTimelineEvent>[
    PlannerTimelineEvent(
      kind: PlannerTimelineEventKind.scheduled,
      atUtc: item.scheduledInstantUtc,
    ),
  ];
  if (item.alarm?.rangAt case final at?) {
    events.add(
      PlannerTimelineEvent(kind: PlannerTimelineEventKind.rang, atUtc: at),
    );
  }
  if (item.alarm?.dismissedAt case final at?) {
    events.add(
      PlannerTimelineEvent(kind: PlannerTimelineEventKind.dismissed, atUtc: at),
    );
  }
  switch (item.outcome) {
    case ScheduleOutcome(result: OutcomeResult.done, :final completedAt):
      events.add(
        PlannerTimelineEvent(
          kind: PlannerTimelineEventKind.done,
          atUtc: completedAt,
        ),
      );
    case ScheduleOutcome(result: OutcomeResult.skipped, :final skippedAt):
      events.add(
        PlannerTimelineEvent(
          kind: PlannerTimelineEventKind.skipped,
          atUtc: skippedAt,
        ),
      );
    case null:
      events.add(
        const PlannerTimelineEvent(
          kind: PlannerTimelineEventKind.pendingOutcome,
        ),
      );
  }
  return events;
}
