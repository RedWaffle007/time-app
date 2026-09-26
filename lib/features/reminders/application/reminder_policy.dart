import '../../scheduling/domain/schedule_item.dart';
import '../domain/reminder.dart';

/// **The one rule for whether an item gets a reminder**, and the only place the
/// reminder layer is allowed to know what a [ScheduleItem] is.
///
/// Everything downstream sees [ReminderRequest]s. That boundary is what lets
/// the reconciler be a pure function over instants and strings, and it is what
/// stops "should this fire?" from being re-decided, differently, at four
/// transition call sites.
///
/// An item is reminded when ALL of:
///
///   * **the signed-in user is the target.** A planner is not reminded of a plan
///     they wrote for someone else — they get the outcome push instead. A
///     self-planned item satisfies this, because there the two are the same
///     person.
///   * **status is `approved`.** Consent is the product's whole premise: a
///     `pending` item has not been agreed to, and an alarm for something you
///     have not accepted is exactly the imposition the consent model exists to
///     prevent. `rejected`, `withdrawn` and `cancelled` are self-evident.
///   * **no outcome is recorded.** Done or skipped means the moment has been
///     answered; reminding afterwards is noise.
///   * **the instant is in the future.** Nothing is retroactive.
///
/// Archive state is deliberately NOT consulted. Archiving is a per-user *view*
/// rule for settled items (`schedule_providers.dart`), and a live item is
/// unarchivable by either route — so the outcome test already covers it. Reading
/// the filtered view here would couple the reminder layer to a UI concern and
/// give it a second, drifting definition of "live".
///
/// **No quiet-hours filtering.** Quiet hours are still warnings-only, and
/// enforcement is explicitly parked to a later part (CLAUDE.md). Applying them
/// here would silently drop reminders the user approved.
///
/// [plannerNames] (uid → display name) feeds the alarm sentence; a name not
/// yet loaded falls back to "Someone" and re-arms once it arrives (the title is
/// part of the fingerprint).
List<ReminderRequest> desiredReminders({
  required List<ScheduleItem> items,
  required String? uid,
  required DateTime now,
  Map<String, String> plannerNames = const {},
}) {
  if (uid == null) return const [];
  return [
    for (final item in items)
      if (item.targetUid == uid &&
          item.status == ScheduleItemStatus.approved &&
          item.outcome == null &&
          item.scheduledInstantUtc.isAfter(now))
        ReminderRequest(
          itemId: item.id,
          fireAtUtc: item.scheduledInstantUtc,
          title: alarmHeadline(
            item,
            plannerName: plannerNames[item.createdByUid],
          ),
          body: reminderBody(item),
          // Someone else's voice note plays instead of the ringtone (32c-2).
          voice: item.voiceNote != null && item.createdByUid != item.targetUid
              ? ReminderVoice(
                  sha256: item.voiceNote!.sha256,
                  sizeBytes: item.voiceNote!.sizeBytes,
                )
              : null,
        ),
  ];
}

/// **The one sentence an alarm says** — on the full-screen alarm, the unlocked
/// heads-up and the missed-alarm notice: "{planner} planned {task} for you", or "You
/// planned Walk" for a self-plan. A name that is not known yet reads
/// "Someone"; never a uid.
String alarmHeadline(ScheduleItem item, {String? plannerName}) {
  final title = item.title.trim();
  if (item.createdByUid == item.targetUid) return 'You planned $title';
  final name = plannerName?.trim();
  final who = name == null || name.isEmpty ? 'Someone' : name;
  // A voice alarm has no task name (F4): the recording is the message.
  if (item.voiceNote != null) return '$who sent you a voice alarm';
  return '$who planned $title for you';
}

/// The uids whose names the alarm sentence needs: the planners of items that
/// will be reminded (other people only — a self-plan needs no name).
Set<String> reminderPlannerUids(
  List<ScheduleItem> items, {
  required String? uid,
  required DateTime now,
}) => {
  for (final request in desiredReminders(items: items, uid: uid, now: now))
    for (final item in items)
      if (item.id == request.itemId && item.createdByUid != item.targetUid)
        item.createdByUid,
};

/// The notification's second line.
///
/// Deliberately does NOT restate the time. Rendering a date needs the device
/// locale and its 12h/24h setting, which lives behind
/// `core/format/datetime_format.dart` and needs a `BuildContext` — and there is
/// no context in a scheduler. Hardcoding a format here would break the standing
/// worldwide requirement outright. It would also be redundant: the notification
/// arrives *at* the time, so the time is the one fact the user already has.
///
/// The planner's note is the useful thing to carry instead, when there is one.
String reminderBody(ScheduleItem item) {
  final note = item.note?.trim();
  if (note != null && note.isNotEmpty) return note;
  return 'Tap to mark it done or skip.';
}
