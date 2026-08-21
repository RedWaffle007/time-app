import '../domain/reminder.dart';

/// One thing to tell the OS.
class ReminderScheduleAction {
  const ReminderScheduleAction(this.request, this.notificationId);
  final ReminderRequest request;
  final int notificationId;

  @override
  String toString() => 'schedule(${request.itemId} #$notificationId)';
}

/// The difference between what the app wants and what it believes it has.
class ReminderPlan {
  const ReminderPlan({
    required this.toSchedule,
    required this.toCancel,
    required this.mirror,
  });

  final List<ReminderScheduleAction> toSchedule;
  final List<int> toCancel;

  /// The mirror as it will be once the plan is applied. Written only after the
  /// OS calls succeed — see [ReminderService].
  final List<ScheduledReminder> mirror;

  bool get isEmpty => toSchedule.isEmpty && toCancel.isEmpty;

  @override
  String toString() =>
      'ReminderPlan(schedule: ${toSchedule.length}, cancel: ${toCancel.length})';
}

/// **The whole brain of the reminder layer, and a pure function.**
///
/// No plugins, no Firestore, no clock of its own — [now] is a parameter — so
/// every rule below is testable at speed with no device. That is deliberate:
/// this is the code whose bugs are invisible (a reminder that silently never
/// arrives), so it is the code that must not need a phone to check.
///
/// **Idempotent by construction.** Applying a plan and then reconciling the same
/// desire against the resulting mirror produces an empty plan. That is what
/// makes it safe to run this on every item-stream emission, on app start and on
/// every resume — the common case does nothing at all, and calling it more often
/// can only make the OS state more correct, never less.
///
/// The comparison is by FINGERPRINT, not by presence. An item whose time or
/// title was edited has the same id and the same mirror row but a different
/// fingerprint, so an edit is a re-schedule and needs no special case anywhere
/// else in the feature.
ReminderPlan reconcileReminders({
  required List<ReminderRequest> desired,
  required List<ScheduledReminder> mirror,
  required DateTime now,
}) {
  // Sorted so that id allocation is a deterministic function of the inputs.
  // Firestore snapshot order is not stable, and without this two devices — or
  // the same device twice — could resolve a collision differently.
  final wanted = [
    for (final r in desired)
      // The last guard against arming something in the past. Callers filter too,
      // but this is the one place `now` is in scope, so this is where the rule
      // belongs rather than being trusted to every caller.
      if (r.fireAtUtc.isAfter(now)) r,
  ]..sort((a, b) => a.itemId.compareTo(b.itemId));

  final wantedIds = {for (final r in wanted) r.itemId};
  final mirrorByItem = {for (final m in mirror) m.itemId: m};

  // Anything mirrored that is no longer wanted. This ONE rule covers withdraw,
  // reject, cancel, done, skip, un-approval, an item deleted outright, an item
  // whose time moved into the past, and an item that now belongs to a different
  // account — because each of those simply stops producing a desired entry.
  // Four separate call sites hooked into four transitions would have to be right
  // four times; this has to be right once.
  final toCancel = [
    for (final m in mirror)
      if (!wantedIds.contains(m.itemId)) m.notificationId,
  ];

  // Ids already spoken for. Seeded with every SURVIVING item's current id first,
  // so an unchanged item never has its id moved out from under it by a newcomer
  // that happens to hash to the same value.
  final taken = <int>{
    for (final r in wanted)
      if (mirrorByItem[r.itemId] case final m?) m.notificationId,
  };

  final toSchedule = <ReminderScheduleAction>[];
  final nextMirror = <ScheduledReminder>[];

  for (final request in wanted) {
    final existing = mirrorByItem[request.itemId];
    final id = existing?.notificationId ??
        allocateNotificationId(request.itemId, taken);
    taken.add(id);

    if (existing != null && existing.fingerprint == request.fingerprint) {
      // Already believed scheduled, unchanged. The no-op case, and by far the
      // most common one.
      nextMirror.add(existing);
      continue;
    }

    toSchedule.add(ReminderScheduleAction(request, id));
    nextMirror.add(
      ScheduledReminder(
        itemId: request.itemId,
        notificationId: id,
        fireAtUtc: request.fireAtUtc,
        fingerprint: request.fingerprint,
      ),
    );
  }

  return ReminderPlan(
    toSchedule: toSchedule,
    toCancel: toCancel,
    mirror: nextMirror,
  );
}
