import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// F2 (2026-09-26, user-directed): the per-item approval step is gone. Every
/// alarm a permitted person sets rings directly; the planner may cancel one
/// that has not rung; the Emergency distinction and the approvals UI are
/// retired. These pin that it stays gone.

final _now = DateTime.utc(2030, 1, 1, 9);

ScheduleItem _item({
  ScheduleItemStatus status = ScheduleItemStatus.approved,
  Duration inFuture = const Duration(hours: 1),
  ScheduleOutcome? outcome,
}) => ScheduleItem(
  id: 'i',
  targetUid: 'TARGET',
  createdByUid: 'PLANNER',
  groupId: '',
  title: 'Walk',
  localWallTime: '',
  timezone: 'Etc/UTC',
  scheduledInstantUtc: _now.add(inFuture),
  status: status,
  outcome: outcome,
);

String _read(String path) => File(path).readAsStringSync();

Iterable<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  group('planner cancel', () {
    test('an upcoming alarm nobody answered can be cancelled', () {
      expect(plannerCanCancel(_item(), _now), isTrue);
    });

    test('a legacy pending plan can be cancelled', () {
      expect(
        plannerCanCancel(_item(status: ScheduleItemStatus.pending), _now),
        isTrue,
      );
    });

    test('not once it has rung, been answered, or been settled', () {
      expect(
        plannerCanCancel(_item(inFuture: const Duration(minutes: -1)), _now),
        isFalse,
      );
      expect(
        plannerCanCancel(
          _item(outcome: const ScheduleOutcome(result: OutcomeResult.done)),
          _now,
        ),
        isFalse,
      );
      for (final status in [
        ScheduleItemStatus.withdrawn,
        ScheduleItemStatus.rejected,
      ]) {
        expect(plannerCanCancel(_item(status: status), _now), isFalse);
      }
    });

    test('the Activity card offers "Cancel alarm" through that rule', () {
      final card = _read(
        'lib/features/scheduling/presentation/planner_activity_screen.dart',
      );
      expect(card, contains('plannerCanCancel(item, DateTime.now().toUtc())'));
      expect(card, contains("const Text('Cancel alarm')"));
    });
  });

  group('the approval step is gone', () {
    test('no approvals screen, route, badge or glow remains', () {
      expect(Directory('lib/features/approvals').existsSync(), isFalse);
      for (final f in _dartFiles('lib')) {
        final code = f.readAsStringSync();
        for (final gone in [
          'PendingApprovalsScreen',
          'PendingApprovalsAction',
          'PendingAttentionGlow',
          'planAttentionCountProvider',
          'Routes.approvals',
        ]) {
          expect(code.contains(gone), isFalse, reason: '$gone in ${f.path}');
        }
      }
    });

    test('no screen asks anyone to approve an alarm, or says Emergency', () {
      final quoted = RegExp(r"'([^'\n]*)'");
      for (final f in _dartFiles('lib/features')) {
        for (final line in f.readAsLinesSync()) {
          if (line.trimLeft().startsWith('//')) continue;
          for (final m in quoted.allMatches(line)) {
            final text = m.group(1)!;
            // Group JOIN approval stays. The "Emergency plans" CHANNEL is
            // retired with the tones in F3; until then its name survives.
            if (f.path.contains('/groups/') || text == 'Emergency plans') {
              continue;
            }
            expect(
              RegExp(
                r'sent for approval|you still approve|approve each|'
                r'Approve or reject|Pending approvals',
              ).hasMatch(text),
              isFalse,
              reason: '"$text" in ${f.path}',
            );
            expect(
              RegExp(r'\bEmergency (item|plan|alarm)').hasMatch(text),
              isFalse,
              reason: '"$text" in ${f.path}',
            );
          }
        }
      }
    });

    test('the builder and the group fan-out save approved alarms', () {
      final builder = _read(
        'lib/features/scheduling/presentation/schedule_builder_screen.dart',
      );
      expect(builder, contains('status: ScheduleItemStatus.approved'));
      expect(builder, isNot(contains('iCanEmergencyPlanForProvider')));
      expect(builder, contains("'Send'"));
      final repo = _read(
        'lib/features/scheduling/data/schedule_repository.dart',
      );
      final fanOut = repo.substring(repo.indexOf('planForGroup({'));
      expect(fanOut, contains('status: ScheduleItemStatus.approved'));
      expect(fanOut, isNot(contains('ScheduleItemStatus.pending')));
    });

    test('turning the one permission off revokes BOTH grants', () {
      final profile = _read(
        'lib/features/social/presentation/user_profile_screen.dart',
      );
      final section = profile.substring(
        profile.indexOf('planning-permission-switch'),
      );
      expect(section, contains('value: canPlanForMe || canEmergencyForMe'));
      expect(section, contains('if (!v && canEmergencyForMe)'));
      expect(section, contains('kind: PlanningKind.emergency'));
      expect(
        profile,
        isNot(contains('Let \${widget.name} set emergency alarms')),
      );
    });

    test('plans still waiting become alarms on the target\'s phone', () {
      final reconciler = _read(
        'lib/features/scheduling/application/item_lapse_reconciler.dart',
      );
      expect(reconciler, contains('lapsed.toApprove'));
      expect(reconciler, contains('lapsed.toApproveAndSkip'));
      expect(reconciler, isNot(contains('_repository.reject(')));
    });
  });
}
