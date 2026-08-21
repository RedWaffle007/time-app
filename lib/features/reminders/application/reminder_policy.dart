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
List<ReminderRequest> desiredReminders({
  required List<ScheduleItem> items,
  required String? uid,
  required DateTime now,
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
          title: item.title,
          body: reminderBody(item),
        ),
  ];
}

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
