import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/http_friend_notifier.dart';

/// The two friend-graph push events. A separate family from [NotifyEvent] (the
/// item events) because the recipient rule and the wire shape differ: these
/// carry `{fromUid, toUid}`, never an `itemId`.
///
///   friendRequest   — the SENDER notifies the RECIPIENT that a request arrived.
///   friendAccept    — the ACCEPTER notifies the original SENDER it was accepted.
///   planningRequest — the REQUESTER notifies the target of a planning-permission
///                     request (#4/#5); carries `kind` (normal/emergency).
///   planningApprove — the APPROVER notifies the original requester it was granted.
///
/// The wire value is the enum name, which the Worker matches on. The two
/// planning events ride the same `{fromUid, toUid}` shape plus an optional
/// `kind`. See DECISIONS.md "Friend-request push (2026-08-24)" and
/// "Friendship-scoped planning grants".
enum FriendNotifyEvent {
  friendRequest,
  friendAccept,
  planningRequest,
  planningApprove,
  planRequested,
}

/// The seam between "a friend-graph action happened" and "the other party gets a
/// push", in the same spirit as [NotificationEventNotifier] for items: the UI
/// depends only on this, so the transport (Worker today, a Cloud Function on
/// card-day) can change underneath it.
abstract class FriendEventNotifier {
  Future<void> notify({
    required FriendNotifyEvent event,
    required String fromUid,
    required String toUid,
    // Only the planning events carry it (normal/emergency); it just changes the
    // push copy and is validated by the Worker.
    String? kind,
    String? planRequestId,
  });
}

/// The card-day implementation: does nothing, because a Firestore-triggered
/// function would send on the write itself.
class NoopFriendEventNotifier implements FriendEventNotifier {
  const NoopFriendEventNotifier();

  @override
  Future<void> notify({
    required FriendNotifyEvent event,
    required String fromUid,
    required String toUid,
    String? kind,
    String? planRequestId,
  }) async {}
}

final friendEventNotifierProvider = Provider<FriendEventNotifier>((ref) {
  return HttpFriendEventNotifier();
});
