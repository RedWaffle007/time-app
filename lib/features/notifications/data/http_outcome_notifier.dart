import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/notify_config.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../application/outcome_notifier.dart';

/// Client-triggered transport: POST the outcome to the Cloudflare Worker with
/// the caller's Firebase ID token. Best-effort by design — a failure here means
/// the *push* is missed, never the *outcome* (which is already written to
/// Firestore and shown in the in-app live view). We deliberately do NOT retry;
/// see the "silent-miss failure mode" note in DECISIONS.md.
class HttpOutcomeNotifier implements OutcomeNotifier {
  @override
  Future<void> notifyOutcome({
    required String targetUid,
    required String itemId,
    required OutcomeResult outcome,
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
              'targetUid': targetUid,
              'itemId': itemId,
              'outcome': outcome == OutcomeResult.done ? 'done' : 'skipped',
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e, st) {
      // Safety net is the in-app outcomes view; a missed push is tolerable at N=2.
      // Record it so an otherwise-silent push failure is visible remotely — this
      // is the exact "friend marks done, planner never notified, I see nothing"
      // case we could not diagnose without USB otherwise.
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'outcome push to Worker failed (outcome still saved)',
        fatal: false,
      );
      debugPrint('OutcomeNotifier: push call failed (outcome still saved): $e');
    }
  }
}
