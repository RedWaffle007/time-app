import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/scheduling/application/item_lapse_policy.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

/// The client half of the lapse-deadline parity check. The Worker settles
/// lapses server-side (item 20) with its own JS implementation; both must
/// produce exactly the instants in the shared fixture, or they would settle the
/// same item at different times.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  final fixture =
      jsonDecode(
            File('test/fixtures/response_deadlines.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  for (final raw in fixture['cases'] as List) {
    final c = raw as Map<String, dynamic>;
    test(c['name'] as String, () {
      final item = ScheduleItem(
        id: 'x',
        targetUid: 't',
        createdByUid: 'p',
        groupId: '',
        title: 'x',
        localWallTime: '',
        timezone: c['zone'] as String,
        scheduledInstantUtc: DateTime.parse(c['scheduled'] as String),
        status: ScheduleItemStatus.approved,
      );
      expect(
        responseDeadlineUtc(item),
        DateTime.parse(c['deadline'] as String),
      );
    });
  }
}
