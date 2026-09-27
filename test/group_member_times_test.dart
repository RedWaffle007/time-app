import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/scheduling/application/group_member_times.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// "Everyone's time", grouped by timezone (2026-09-27).
void main() {
  setUpAll(tzdata.initializeTimeZones);
  final now = DateTime.utc(2026, 9, 27, 12); // noon UTC

  ({String uid, String name, bool isSelf, String? zone, bool busy}) m(
    String uid,
    String? zone, {
    bool self = false,
    bool busy = false,
  }) => (uid: uid, name: 'Name $uid', isSelf: self, zone: zone, busy: busy);

  test('one group per zone; yours first, then west to east, unknown last', () {
    final groups = groupMembersByZone([
      m('k1', 'Asia/Kolkata'),
      m('none', null),
      m('me', 'Europe/London', self: true),
      m('v1', 'America/Vancouver'),
      m('k2', 'Asia/Kolkata'),
    ], nowUtc: now);
    expect(groups.map((g) => g.zone), [
      'Europe/London',
      'America/Vancouver',
      'Asia/Kolkata',
      null,
    ]);
    expect(groups[2].members.map((x) => x.uid), ['k1', 'k2']);
    expect(groups.last.wallNow, isNull);
  });

  test('each zone carries its own wall time', () {
    final groups = groupMembersByZone([
      m('k1', 'Asia/Kolkata', self: true),
    ], nowUtc: now);
    expect(groups.single.wallNow, DateTime(2026, 9, 27, 17, 30));
  });

  test('inside a zone: you first, then by name; busy is kept', () {
    final groups = groupMembersByZone([
      (uid: 'b', name: 'Bee', isSelf: false, zone: 'UTC', busy: true),
      (uid: 'a', name: 'Aye', isSelf: false, zone: 'UTC', busy: false),
      (uid: 'me', name: 'You', isSelf: true, zone: 'UTC', busy: false),
    ], nowUtc: now);
    final members = groups.single.members;
    expect(members.map((x) => x.uid), ['me', 'a', 'b']);
    expect(members.last.busy, isTrue);
  });

  test('forty members in three zones make three groups', () {
    const zones = ['Asia/Kolkata', 'Europe/London', 'America/Chicago'];
    final groups = groupMembersByZone([
      for (var i = 0; i < 40; i++) m('M$i', zones[i % 3]),
    ], nowUtc: now);
    expect(groups, hasLength(3));
    expect(groups.fold<int>(0, (n, g) => n + g.members.length), 40);
  });

  test('zone ids read as city names', () {
    expect(zoneCityName('Asia/Kolkata'), 'Kolkata');
    expect(zoneCityName('America/Argentina/Buenos_Aires'), 'Buenos Aires');
    expect(zoneCityName('UTC'), 'UTC');
  });
}
