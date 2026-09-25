import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/notify_config.dart';
import '../application/friend_notifier.dart';

/// Client-triggered friend-graph push, POSTed to the same Cloudflare Worker as
/// item events with the caller's Firebase ID token. Same discipline as
/// [HttpEventNotifier]: **best-effort**, no retry — a failure here loses the
/// push, never the state (the friendship / request is already in Firestore and
/// shown in the live views).
///
/// The ID token identifies the ACTOR; the Worker authorizes per event (the
/// caller must own the pending request, or be a party to the friendship) and
/// reads the actor's display name itself, so nothing user-facing is trusted from
/// the client — only `event`, `fromUid`, `toUid` are sent.
class HttpFriendEventNotifier implements FriendEventNotifier {
  @override
  Future<void> notify({
    required FriendNotifyEvent event,
    required String fromUid,
    required String toUid,
    String? kind,
    String? planRequestId,
  }) async {
    if (kNotifyEndpoint.isEmpty) return; // Worker not deployed yet.

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final idToken = await user.getIdToken();
      await http
          .post(
            Uri.parse(kNotifyEndpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode({
              'event': event.name,
              'fromUid': fromUid,
              'toUid': toUid,
              'kind': ?kind,
              'planRequestId': ?planRequestId,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'friend push to Worker failed (state still saved)',
        fatal: false,
      );
      debugPrint('FriendNotifier: push call failed (state still saved): $e');
    }
  }
}
