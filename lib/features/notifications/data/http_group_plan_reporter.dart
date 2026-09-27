import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/notify_config.dart';
import '../application/group_plan_reporter.dart';

/// POSTs `groupPlanned` to the same Cloudflare Worker as every other push,
/// with the caller's Firebase ID token. Unlike the fire-and-forget notifiers it
/// waits (bounded) for the answer, because the answer is what the app shows.
class HttpGroupPlanReporter implements GroupPlanReporter {
  @override
  Future<Set<String>?> availability({
    required String groupId,
    required List<({String uid, DateTime instantUtc})> members,
  }) => fetchAvailability(groupId: groupId, members: members);

  @override
  Future<Set<String>?> reportBusy({
    required String groupId,
    required String title,
    required int setCount,
    required List<({String uid, DateTime instantUtc})> failed,
  }) async {
    if (kNotifyEndpoint.isEmpty || failed.isEmpty) return null;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    try {
      final idToken = await user.getIdToken().timeout(
        const Duration(seconds: 8),
      );
      final response = await http
          .post(
            Uri.parse(kNotifyEndpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode({
              'event': 'groupPlanned',
              'groupId': groupId,
              'title': title,
              'setCount': setCount,
              'busy': [
                for (final f in failed)
                  {
                    'uid': f.uid,
                    'instantUtc': f.instantUtc.toUtc().toIso8601String(),
                  },
              ],
            }),
          )
          .timeout(const Duration(seconds: 10));
      return busyUidsFromWorkerResponse(response.statusCode, response.body);
    } catch (e) {
      debugPrint('GroupPlanReporter: report failed: $e');
      return null;
    }
  }
}

/// POSTs `groupAvailability`: the before-Send busy preview (no pushes).
extension HttpGroupAvailability on HttpGroupPlanReporter {
  Future<Set<String>?> fetchAvailability({
    required String groupId,
    required List<({String uid, DateTime instantUtc})> members,
  }) async {
    if (kNotifyEndpoint.isEmpty || members.isEmpty) return null;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    try {
      final idToken = await user.getIdToken().timeout(
        const Duration(seconds: 8),
      );
      final response = await http
          .post(
            Uri.parse(kNotifyEndpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode({
              'event': 'groupAvailability',
              'groupId': groupId,
              'members': [
                for (final m in members)
                  {
                    'uid': m.uid,
                    'instantUtc': m.instantUtc.toUtc().toIso8601String(),
                  },
              ],
            }),
          )
          .timeout(const Duration(seconds: 10));
      return busyUidsFromWorkerResponse(response.statusCode, response.body);
    } catch (e) {
      debugPrint('GroupPlanReporter: availability failed: $e');
      return null;
    }
  }
}

/// The verified busy uids from the Worker's answer, or null if it is not a
/// usable success. Pure, so it is tested without a network.
Set<String>? busyUidsFromWorkerResponse(int statusCode, String body) {
  if (statusCode != 200) return null;
  try {
    final decoded = jsonDecode(body);
    final list = decoded is Map ? decoded['busyUids'] : null;
    if (list is! List) return null;
    return {
      for (final uid in list)
        if (uid is String) uid,
    };
  } catch (_) {
    return null;
  }
}
