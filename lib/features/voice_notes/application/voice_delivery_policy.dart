import '../../scheduling/domain/schedule_item.dart';

/// Which voice notes this device must hold, as a pure rule (item 32c) — the
/// same stream-driven shape as the reminder and lapse reconcilers: applied to
/// whatever the item stream says, never hooked to a transition.
class VoiceDeliveryPlan {
  const VoiceDeliveryPlan({
    required this.fetch,
    required this.receipt,
    required this.keepIds,
  });

  /// Approved, unanswered, still-future alarms of mine with a voice note: the
  /// verified copy must be on this phone before they ring.
  final List<ScheduleItem> fetch;

  /// Of [fetch], those whose delivery receipt is not stamped yet.
  final List<ScheduleItem> receipt;

  /// Every item id whose local copy is still wanted (the rest are deleted):
  /// anything still live — pending (for the approval preview) or approved and
  /// unanswered — until a day after its scheduled time.
  final Set<String> keepIds;
}

const kVoiceKeepAfterDue = Duration(hours: 26);

VoiceDeliveryPlan planVoiceDelivery(
  List<ScheduleItem> items,
  String myUid,
  DateTime nowUtc,
) {
  final now = nowUtc.toUtc();
  final fetch = <ScheduleItem>[];
  final keep = <String>{};
  for (final item in items) {
    if (item.targetUid != myUid || item.voiceNote == null) continue;
    if (item.createdByUid == myUid) continue; // never on self-plans
    final live =
        item.outcome == null &&
        (item.status == ScheduleItemStatus.pending ||
            item.status == ScheduleItemStatus.approved);
    if (!live) continue;
    if (now.isBefore(item.scheduledInstantUtc.add(kVoiceKeepAfterDue))) {
      keep.add(item.id);
    }
    if (item.status == ScheduleItemStatus.approved &&
        item.scheduledInstantUtc.isAfter(now)) {
      fetch.add(item);
    }
  }
  return VoiceDeliveryPlan(
    fetch: fetch,
    receipt: [
      for (final item in fetch)
        if (item.voiceNote!.deliveredAt == null) item,
    ],
    keepIds: keep,
  );
}

/// What the PLANNER is told about their voice note on an item's card, or
/// null when there is nothing to say (no note, or the alarm is settled).
String? plannerVoiceNoteStatus(ScheduleItem item) {
  final note = item.voiceNote;
  if (note == null || item.outcome != null) return null;
  return switch (item.status) {
    ScheduleItemStatus.pending => 'Voice note attached',
    ScheduleItemStatus.approved =>
      note.deliveredAt != null
          ? 'Voice note on their phone'
          : 'Voice note not on their phone yet',
    _ => null,
  };
}
