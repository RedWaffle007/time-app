import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/reminders/application/reminder_policy.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// The client half of the alarm-sentence parity check (R3, 2026-10-02). A
/// killed-app alarm is armed from the Worker's push, so the Worker builds the
/// same sentence as [alarmHeadline]; both must produce exactly the strings in
/// the shared fixture, or a killed-app alarm would lose the planner's name.
void main() {
  final cases =
      jsonDecode(
            File('test/fixtures/alarm_headline_cases.json').readAsStringSync(),
          )
          as List;

  for (final raw in cases) {
    final c = raw as Map<String, dynamic>;
    final spec = c['item'] as Map<String, dynamic>;
    test(c['name'] as String, () {
      final item = ScheduleItem(
        id: 'x',
        targetUid: spec['targetUid'] as String,
        createdByUid: spec['createdByUid'] as String,
        groupId: '',
        title: spec['title'] as String,
        localWallTime: '',
        timezone: 'Etc/UTC',
        scheduledInstantUtc: DateTime.utc(2030),
        status: ScheduleItemStatus.approved,
        voiceNote: spec['voiceNote'] == true
            ? const VoiceNoteMeta(
                durationMs: 5000,
                sha256:
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                sizeBytes: 100,
              )
            : null,
      );
      expect(
        alarmHeadline(item, plannerName: c['plannerName'] as String?),
        c['expected'],
      );
    });
  }
}
