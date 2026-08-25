import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/http_friend_notifier.dart';

/// The two friend-graph push events. A separate family from [NotifyEvent] (the
/// item events) because the recipient rule and the wire shape differ: these
/// carry `{fromUid, toUid}`, never an `itemId`.
///
///   friendRequest — the SENDER notifies the RECIPIENT that a request arrived.
///   friendAccept  — the ACCEPTER notifies the original SENDER it was accepted.
///
/// The wire value is the enum name (`friendRequest` / `friendAccept`), which the
/// Worker matches on. See DECISIONS.md "Friend-request push (2026-08-24)".
enum FriendNotifyEvent { friendRequest, friendAccept }

/// The seam between "a friend-graph action happened" and "the other party gets a
/// push", in the same spirit as [NotificationEventNotifier] for items: the UI
/// depends only on this, so the transport (Worker today, a Cloud Function on
/// card-day) can change underneath it.
abstract class FriendEventNotifier {
  Future<void> notify({
    required FriendNotifyEvent event,
    required String fromUid,
    required String toUid,
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
  }) async {}
}

final friendEventNotifierProvider = Provider<FriendEventNotifier>((ref) {
  return HttpFriendEventNotifier();
});
