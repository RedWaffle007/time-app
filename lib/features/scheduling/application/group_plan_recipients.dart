/// Who a "Plan for the group" send reaches (item 15, 2026-09-26).
///
/// There is NO group-level emergency permission: an emergency group plan goes
/// only to members who gave the planner their own (friendship) emergency
/// grant, plus the planner themselves. Everyone else the planner can normally
/// plan for is reported as skipped, never silently downgraded to a normal plan.
///
/// [candidates] are the NORMAL recipients (self + members with a normal
/// grant); [emergencyUids] are other members the planner may emergency-plan
/// for. Pure, so the rule is unit-tested without a device.
({List<({String uid, bool isSelf})> recipients, List<String> skippedUids})
groupPlanRecipients({
  required List<({String uid, bool isSelf})> candidates,
  required Set<String> emergencyUids,
  required bool emergency,
}) {
  if (!emergency) return (recipients: candidates, skippedUids: const []);
  final self = [
    for (final c in candidates)
      if (c.isSelf) c,
  ];
  final selfUids = {for (final c in self) c.uid};
  final others = [
    for (final uid in emergencyUids)
      if (!selfUids.contains(uid)) (uid: uid, isSelf: false),
  ]..sort((a, b) => a.uid.compareTo(b.uid));
  final skipped = [
    for (final c in candidates)
      if (!c.isSelf && !emergencyUids.contains(c.uid)) c.uid,
  ];
  return (recipients: [...self, ...others], skippedUids: skipped);
}
