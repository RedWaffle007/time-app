import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/http_event_notifier.dart';

/// The four notification events on the ONE generalized endpoint (Group A).
/// Two are planner-triggered (notify the target); two are target-triggered
/// (notify the planner). The wire value is the enum name.
enum NotifyEvent {
  /// Planner created a plan → notify the target.
  created,

  /// Target approved/rejected → notify the planner. Sub-type derived server-side.
  decided,

  /// Target marked done/skipped → notify the planner. Sub-type derived server-side.
  outcome,

  /// Planner withdrew a still-pending plan → notify the target.
  withdrawn,

  /// Target dismissed the ringing alarm → notify the planner. Requires the
  /// durable `alarm.dismissedAt`, which the Worker re-reads.
  dismissed,
}

/// The app's seam between "something happened to an item" and "the other party
/// gets a push." The UI depends ONLY on this abstraction — never on the Worker
/// URL — so the transport can change underneath it.
///
/// Card-day (see DECISIONS.md): when push moves to a Firestore-triggered Cloud
/// Function, swap [notificationEventNotifierProvider] to return [NoopEventNotifier]
/// — the server then fires on the write and this call becomes a no-op. That is
/// the ONLY app-side change required.
abstract class NotificationEventNotifier {
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  });

  /// Same send, with the Worker's actual delivery result exposed to flows that
  /// must not claim the recipient was notified when FCM had no usable token.
  Future<NotificationDeliveryResult> notifyConfirmed({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  });
}

class NotificationDeliveryResult {
  const NotificationDeliveryResult({
    required this.delivered,
    required this.reason,
  });

  final bool delivered;
  final String reason;
}

/// The card-day implementation: does nothing, because the server sends on write.
class NoopEventNotifier implements NotificationEventNotifier {
  const NoopEventNotifier();

  @override
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async {}

  @override
  Future<NotificationDeliveryResult> notifyConfirmed({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
  }) async => const NotificationDeliveryResult(
    delivered: true,
    reason: 'server-triggered',
  );
}

final notificationEventNotifierProvider = Provider<NotificationEventNotifier>((
  ref,
) {
  // No-card transport for now. Swap to `const NoopEventNotifier()` on card-day.
  return HttpEventNotifier();
});
