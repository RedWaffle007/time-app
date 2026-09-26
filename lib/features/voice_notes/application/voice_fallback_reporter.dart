import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../notifications/application/outcome_notifier.dart';

/// Item 32c-2: when a voice-note alarm had to ring the normal ringtone, the
/// target's phone stamps the permanent fact `alarm.voiceFallbackAt` (first
/// observation only) and asks the Worker to tell the planner. The Worker
/// re-reads that fact before sending, and sends at most once.
class VoiceFallbackReporter {
  VoiceFallbackReporter(this._db, this._notifier);

  final FirebaseFirestore _db;
  final NotificationEventNotifier _notifier;

  /// True once the fact is stored (the native event can then be dropped).
  Future<bool> report(String uid, String itemId, DateTime atUtc) async {
    final ref = _db
        .collection('scheduleItems')
        .doc(uid)
        .collection('items')
        .doc(itemId);
    try {
      await _db.runTransaction((transaction) async {
        final snapshot = await transaction.get(ref);
        final data = snapshot.data();
        if (data == null) return;
        final alarm = data['alarm'];
        if (alarm is Map && alarm['voiceFallbackAt'] != null) return;
        transaction.update(ref, {
          'alarm.voiceFallbackAt': Timestamp.fromDate(atUtc.toUtc()),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (_) {
      return false; // offline: kept for the next pass
    }
    unawaited(
      _notifier.notify(
        event: NotifyEvent.voiceFallback,
        targetUid: uid,
        itemId: itemId,
      ),
    );
    return true;
  }
}
