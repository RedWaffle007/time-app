import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/reminders/application/dismiss_notifying_timeline.dart';
import 'package:time_app/features/reminders/data/alarm_timeline_repository.dart';
import 'package:time_app/features/scheduling/presentation/schedule_builder_screen.dart';

/// 2026-09-27 device fixes: Send misreported a delivered push after a slow
/// Worker reply, and one dismissal reached the planner three times.
void main() {
  group('sendConfirmationText', () {
    NotificationDeliveryResult r(bool delivered, String reason) =>
        NotificationDeliveryResult(delivered: delivered, reason: reason);

    test('delivered → sent', () {
      expect(
        sendConfirmationText(
          delivery: r(true, 'sent'),
          isSelf: false,
          isVoice: true,
        ),
        'Voice alarm sent.',
      );
    });

    test('a timeout never claims the notification failed', () {
      final text = sendConfirmationText(
        delivery: r(false, 'transport-error:TimeoutException'),
        isSelf: false,
        isVoice: true,
      );
      expect(text, startsWith('Voice alarm sent.'));
      expect(text, isNot(contains('not notified')));
      expect(text, isNot(contains('not delivered')));
    });

    test('a definite Worker "no phone" answer is still reported', () {
      final text = sendConfirmationText(
        delivery: r(false, 'no-tokens'),
        isSelf: false,
        isVoice: false,
      );
      expect(text, contains('was not notified'));
    });

    test('self-plans say added', () {
      expect(
        sendConfirmationText(delivery: null, isSelf: true, isVoice: false),
        'Added to your schedule.',
      );
    });
  });

  group('DismissNotifyingTimelineRepository', () {
    test('three reports of one dismissal notify once', () async {
      final notifier = _Notifier();
      final repo = DismissNotifyingTimelineRepository(_Timeline(), notifier);
      final at = DateTime.utc(2030);
      await Future.wait([
        repo.recordDismissed('TARGET', 'item-1', at),
        repo.recordDismissed('TARGET', 'item-1', at),
        repo.recordDismissed('TARGET', 'item-1', at),
      ]);
      await pumpEventQueue();
      expect(notifier.calls, ['dismissed:item-1']);
    });

    test('dismissed and unavailable are separate events', () async {
      final notifier = _Notifier();
      final repo = DismissNotifyingTimelineRepository(_Timeline(), notifier);
      final at = DateTime.utc(2030);
      await repo.recordUnavailable('TARGET', 'item-1', at);
      await repo.recordDismissed('TARGET', 'item-1', at);
      await pumpEventQueue();
      expect(notifier.calls, ['unavailable:item-1', 'dismissed:item-1']);
    });

    test('a report that never reached the Worker may be retried', () async {
      final notifier = _Notifier(reason: 'transport-error:SocketException');
      final repo = DismissNotifyingTimelineRepository(_Timeline(), notifier);
      final at = DateTime.utc(2030);
      await repo.recordDismissed('TARGET', 'item-1', at);
      await pumpEventQueue();
      await repo.recordDismissed('TARGET', 'item-1', at);
      await pumpEventQueue();
      expect(notifier.calls, ['dismissed:item-1', 'dismissed:item-1']);
    });
  });
}

class _Timeline implements AlarmTimelineRepository {
  @override
  Future<void> recordDismissed(String t, String i, DateTime at) async {}
  @override
  Future<void> recordRang(String t, String i, DateTime at) async {}
  @override
  Future<void> recordUnavailable(String t, String i, DateTime at) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifier implements NotificationEventNotifier {
  _Notifier({this.reason = 'sent'});

  final String reason;
  final calls = <String>[];

  @override
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async => calls.add('${event.name}:$itemId');

  @override
  Future<NotificationDeliveryResult> notifyConfirmed({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async {
    calls.add('${event.name}:$itemId');
    return NotificationDeliveryResult(
      delivered: reason == 'sent',
      reason: reason,
    );
  }
}
