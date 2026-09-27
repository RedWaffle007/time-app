import '../../../core/timezone/tz_resolver.dart';

/// One member row in the "Everyone's time" view.
class MemberTime {
  const MemberTime({
    required this.uid,
    required this.name,
    required this.isSelf,
    required this.busy,
  });

  final String uid;
  final String name;
  final bool isSelf;

  /// Verified busy at the chosen minute (won't get this alarm).
  final bool busy;
}

/// Members who share one timezone, with that zone's current wall time.
class ZoneGroup {
  const ZoneGroup({
    required this.zone,
    required this.wallNow,
    required this.members,
  });

  /// IANA id, or null when the member has no known zone.
  final String? zone;
  final DateTime? wallNow;
  final List<MemberTime> members;
}

/// **The group timezone view, grouped** (2026-09-27): one entry per timezone
/// instead of one line per member, so it stays readable at any group size.
///
/// Your own zone first, then the rest from the earliest local time to the
/// latest (west to east), members with no known zone last. Inside a zone:
/// you first, then by name. Pure; `nowUtc` is injected for tests.
List<ZoneGroup> groupMembersByZone(
  List<({String uid, String name, bool isSelf, String? zone, bool busy})>
  members, {
  DateTime? nowUtc,
}) {
  final now = (nowUtc ?? DateTime.now()).toUtc();
  final byZone = <String?, List<MemberTime>>{};
  for (final m in members) {
    final zone = (m.zone == null || m.zone!.isEmpty) ? null : m.zone;
    byZone
        .putIfAbsent(zone, () => [])
        .add(
          MemberTime(uid: m.uid, name: m.name, isSelf: m.isSelf, busy: m.busy),
        );
  }
  final groups = [
    for (final entry in byZone.entries)
      ZoneGroup(
        zone: entry.key,
        wallNow: entry.key == null ? null : wallNowIn(entry.key!, nowUtc: now),
        members: entry.value
          ..sort((a, b) {
            if (a.isSelf != b.isSelf) return a.isSelf ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          }),
      ),
  ];
  final nowWall = DateTime(now.year, now.month, now.day, now.hour, now.minute);
  int offset(ZoneGroup g) => g.wallNow!.difference(nowWall).inMinutes;
  groups.sort((a, b) {
    final aSelf = a.members.any((m) => m.isSelf);
    final bSelf = b.members.any((m) => m.isSelf);
    if (aSelf != bSelf) return aSelf ? -1 : 1;
    if ((a.zone == null) != (b.zone == null)) return a.zone == null ? 1 : -1;
    if (a.zone == null) return 0;
    final byOffset = offset(a).compareTo(offset(b));
    return byOffset != 0 ? byOffset : a.zone!.compareTo(b.zone!);
  });
  return groups;
}

/// A zone id as people read it: "Asia/Kolkata" → "Kolkata",
/// "America/Argentina/Buenos_Aires" → "Buenos Aires".
String zoneCityName(String zone) => zone.split('/').last.replaceAll('_', ' ');
