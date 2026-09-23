import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/completion_celebration.dart';

abstract interface class CompletionCelebrationStore {
  Stream<List<CompletionCelebration>> watchUnseen(String uid);
  Future<void> acknowledge(CompletionCelebration event, String uid);
}

class CompletionCelebrationRepository implements CompletionCelebrationStore {
  CompletionCelebrationRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _events =>
      _db.collection('completionCelebrations');

  @override
  Stream<List<CompletionCelebration>> watchUnseen(String uid) {
    return _events.where('participantUids', arrayContains: uid).snapshots().map(
      (snapshot) {
        final events = snapshot.docs
            .map(CompletionCelebration.fromDoc)
            .where((event) => event.isUnseenBy(uid))
            .toList();
        events.sort((a, b) {
          final aTime = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return aTime.compareTo(bTime);
        });
        return events;
      },
    );
  }

  /// Acknowledge only after the 1.4-second display finishes. The last unseen
  /// participant deletes the event atomically; otherwise this uid is appended.
  @override
  Future<void> acknowledge(CompletionCelebration event, String uid) {
    final ref = _events.doc(event.id);
    return _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      final data = snapshot.data();
      if (data == null) {
        return;
      }
      final participants = List<String>.from(
        data['participantUids'] ?? const [],
      );
      final seen = List<String>.from(data['seenByUids'] ?? const []);
      if (!participants.contains(uid) || seen.contains(uid)) {
        return;
      }
      final remaining = participants.where(
        (id) => id != uid && !seen.contains(id),
      );
      if (remaining.isEmpty) {
        transaction.delete(ref);
      } else {
        transaction.update(ref, {
          'seenByUids': FieldValue.arrayUnion([uid]),
        });
      }
    });
  }
}
