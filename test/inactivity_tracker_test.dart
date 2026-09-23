import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/notifications/application/inactivity_tracker.dart';
import 'package:time_app/features/notifications/data/inactivity_repository.dart';

class _RecordingRepository implements InactivityRepository {
  final writes = <(String, DateTime)>[];

  @override
  Future<void> recordActivity(String uid, DateTime occurredAtUtc) async {
    writes.add((uid, occurredAtUtc));
  }
}

void main() {
  test(
    'first use writes immediately and rapid use is trailing-coalesced',
    () async {
      final repository = _RecordingRepository();
      var now = DateTime.utc(2026, 9, 23, 6);
      final tracker = InactivityTracker(
        repository,
        now: () => now,
        writeInterval: const Duration(milliseconds: 10),
      );
      addTearDown(tracker.dispose);

      tracker.record('alice');
      await Future<void>.delayed(Duration.zero);
      expect(repository.writes, [('alice', now)]);

      now = now.add(const Duration(milliseconds: 1));
      tracker.record('alice');
      now = now.add(const Duration(milliseconds: 1));
      tracker.record('alice');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(repository.writes.length, 2);
      expect(repository.writes.last, ('alice', now));
    },
  );

  test('account changes never inherit another account throttle', () async {
    final repository = _RecordingRepository();
    final now = DateTime.utc(2026, 9, 23, 6);
    final tracker = InactivityTracker(repository, now: () => now);
    addTearDown(tracker.dispose);

    tracker.record('alice');
    tracker.record('bob');
    await Future<void>.delayed(Duration.zero);

    expect(repository.writes, [('alice', now), ('bob', now)]);
  });

  test('clear cancels a pending activity write on sign-out', () async {
    final repository = _RecordingRepository();
    var now = DateTime.utc(2026, 9, 23, 6);
    final tracker = InactivityTracker(
      repository,
      now: () => now,
      writeInterval: const Duration(milliseconds: 20),
    );
    addTearDown(tracker.dispose);

    tracker.record('alice');
    now = now.add(const Duration(milliseconds: 1));
    tracker.record('alice');
    tracker.clear();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(repository.writes.length, 1);
  });
}
