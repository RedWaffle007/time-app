import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/notifications/application/outcome_notifier.dart';
import 'package:time_app/features/notifications/data/http_event_notifier.dart';

/// R1 (2026-10-02): the Worker's "already sent" reply is not a failure and
/// must not flood Crashlytics; every real refusal still reports.
void main() {
  test('a delivered push is never reported', () {
    expect(
      shouldReportUndelivered(
        const NotificationDeliveryResult(delivered: true, reason: 'sent'),
      ),
      isFalse,
    );
  });

  test('already-notified is the normal dedup answer, not reported', () {
    expect(
      shouldReportUndelivered(
        const NotificationDeliveryResult(
          delivered: false,
          reason: 'already-notified',
        ),
      ),
      isFalse,
    );
  });

  for (final reason in [
    'no-active-grant',
    'worker-http-404',
    'self-planned',
    'no-tokens',
  ]) {
    test('a real refusal ($reason) is still reported', () {
      expect(
        shouldReportUndelivered(
          NotificationDeliveryResult(delivered: false, reason: reason),
        ),
        isTrue,
      );
    });
  }
}
