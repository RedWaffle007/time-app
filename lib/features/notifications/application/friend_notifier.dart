import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/http_friend_notifier.dart';

/// The two friend-graph push events. A separate family from [NotifyEvent] (the
/// item events) because the recipient rule and the wire shape differ: these
/// carry `{fromUid, toUid}`, never an `itemId`.
///
///   friendRequest   — the SENDER notifies the RECIPIENT that a request arrived.
///   friendAccept    — the ACCEPTER notifies the original SENDER it was accepted.
///   groupJoinApproved — the ADMIN whose approval admitted a candidate
///                     notifies that candidate; carries `groupId`.
///   groupJoinRequested — whoever asked (the candidate with a code, or the
///                     inviting member) notifies EVERY admin (item 3);
///                     carries `groupId`. For a code request from == to.
///
/// The wire value is the enum name, which the Worker matches on. (The
/// planning-permission events were retired on 2026-09-27: friendship is the
/// permission.) See DECISIONS.md "Friend-request push (2026-08-24)".
enum FriendNotifyEvent {
  friendRequest,
  friendAccept,
  planRequested,
  groupJoinApproved,
  groupJoinRequested,

  /// The friend asked declined a plan request; tells the requester
  /// (2026-09-28, an "Uh-Oh!" event).
  planRequestDeclined,
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
    // Carried only by the retired planning-permission events; no current
    // event sets it.
    String? kind,
    String? planRequestId,
    String? groupId,
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
    String? groupId,
  }) async {}
}

final friendEventNotifierProvider = Provider<FriendEventNotifier>((ref) {
  return HttpFriendEventNotifier();
});
