import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/notify_config.dart';
import '../application/outcome_notifier.dart';

/// Client-triggered transport: POST the event to the Cloudflare Worker with the
/// caller's Firebase ID token. Best-effort by design — a failure here means the
/// *push* is missed, never the *state change* (which is already written to
/// Firestore and shown in the in-app live views). We deliberately do NOT retry;
/// see the "silent-miss failure mode" note in DECISIONS.md.
///
/// The ID token identifies the ACTOR, and the Worker authorizes per event: for a
/// planner-triggered event (created/withdrawn) the caller must be the item's
/// creator; for a target-triggered event (decided/outcome) the target. The
/// caller does NOT assert the outcome/decision — the Worker re-reads it from
/// Firestore — so only `event`, `targetUid`, `itemId` are sent.
class HttpEventNotifier implements NotificationEventNotifier {
  @override
  Future<void> notify({
    required NotifyEvent event,
    required String targetUid,
    required String itemId,
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
              'targetUid': targetUid,
              'itemId': itemId,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e, st) {
      // Safety net is the in-app live views; a missed push is tolerable at N=2.
      // Record it so an otherwise-silent push failure is visible remotely — this
      // is the exact "someone acts, the other party is never notified, and I see
      // nothing" case we could not diagnose without USB otherwise.
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'notification push to Worker failed (state still saved)',
        fatal: false,
      );
      debugPrint('EventNotifier: push call failed (state still saved): $e');
    }
  }
}
