import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/timezone/quiet_hours.dart';
import 'package:time_app/core/timezone/tz_resolver.dart';
import 'package:time_app/features/scheduling/application/slot_availability.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/scheduling/domain/slot.dart';

typedef Row = List<int>;

List<Row> _pairwise(List<int> levels) {
  final candidates = <Row>[];
  void build(List<int> prefix) {
    if (prefix.length == levels.length) {
      candidates.add(prefix);
      return;
    }
    for (var value = 0; value < levels[prefix.length]; value++) {
      build([...prefix, value]);
    }
  }

  build(const []);

  final uncovered = <String>{};
  for (var a = 0; a < levels.length; a++) {
    for (var b = a + 1; b < levels.length; b++) {
      for (var va = 0; va < levels[a]; va++) {
        for (var vb = 0; vb < levels[b]; vb++) {
          uncovered.add('$a:$va|$b:$vb');
        }
      }
    }
  }
  Set<String> pairs(Row row) => {
    for (var a = 0; a < row.length; a++)
      for (var b = a + 1; b < row.length; b++) '$a:${row[a]}|$b:${row[b]}',
  };

  final chosen = <Row>[];
  while (uncovered.isNotEmpty) {
    candidates.sort((a, b) {
      final scoreA = pairs(a).where(uncovered.contains).length;
      final scoreB = pairs(b).where(uncovered.contains).length;
      return scoreB.compareTo(scoreA);
    });
    final best = candidates.removeAt(0);
    chosen.add(best);
    uncovered.removeAll(pairs(best));
  }
  return chosen;
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test(
    'pairwise scheduling/quiet-hours array covers every pair with an oracle',
    () {
      const zones = ['UTC', 'Asia/Kolkata', 'America/New_York'];
      const hours = [1, 9, 23];
      const windows = [(0, 0), (9 * 60, 17 * 60), (23 * 60, 6 * 60)];
      const statuses = [
        ScheduleItemStatus.pending,
        ScheduleItemStatus.approved,
        ScheduleItemStatus.rejected,
      ];
      const outcomes = [false, true];
      const future = [false, true];
      final levels = [
        zones.length,
        hours.length,
        windows.length,
        statuses.length,
        outcomes.length,
        future.length,
      ];
    final rows = _pairwise(levels);
    final exhaustive = levels.fold(1, (a, b) => a * b);
    expect(rows, hasLength(13));
    expect(exhaustive, 324); // 24.9x reduction while retaining every pair.

      final seen = <String>{};
      for (final row in rows) {
        for (var a = 0; a < row.length; a++) {
          for (var b = a + 1; b < row.length; b++) {
            seen.add('$a:${row[a]}|$b:${row[b]}');
          }
        }

        final zone = zones[row[0]];
        final hour = hours[row[1]];
        final window = windows[row[2]];
        final status = statuses[row[3]];
        final hasOutcome = outcomes[row[4]];
        final isFuture = future[row[5]];
        final wall = DateTime.utc(2026, 8, 25, hour, 15);
        final instant = resolveWall(wall, zone).utc;
        final now = instant.add(Duration(hours: isFuture ? -1 : 1));
        final outcome = hasOutcome
            ? const ScheduleOutcome(result: OutcomeResult.done)
            : null;
        final item = ScheduleItem(
          id: 'x',
          targetUid: 't',
          createdByUid: 'p',
          groupId: 'g',
          title: 'x',
          localWallTime: '',
          timezone: zone,
          scheduledInstantUtc: instant,
          status: status,
          outcome: outcome,
        );

        final warnings = warningsForInstant(
          instant,
          zone,
          quietStartMinutes: window.$1,
          quietEndMinutes: window.$2,
        );
        expect(
          warnings.quietHours,
          minuteInWindow(hour * 60 + 15, window.$1, window.$2),
        );
        final shouldBlock =
            !hasOutcome &&
            (status == ScheduleItemStatus.pending ||
                status == ScheduleItemStatus.approved);
        expect(blocksSlot(item), shouldBlock);
        expect(
          isInstantBookable(instantUtc: instant, items: [item], now: now),
          isFuture,
          reason: 'existing point alarms never block another plan',
        );
      }

      for (var a = 0; a < levels.length; a++) {
        for (var b = a + 1; b < levels.length; b++) {
          for (var va = 0; va < levels[a]; va++) {
            for (var vb = 0; vb < levels[b]; vb++) {
              expect(seen, contains('$a:$va|$b:$vb'));
            }
          }
        }
      }
    },
  );
}
