import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/tracked_entry.dart';

/// Reads and writes the signed-in user's OWN manual time-tracking entries at
/// `users/{uid}/trackedTime/{entryId}`. Owner-scoped in both directions; there
/// is deliberately no path here that touches another user's tracked time.
class TrackedTimeRepository {
  TrackedTimeRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _entries(String uid) =>
      _db.collection('users').doc(uid).collection('trackedTime');

  /// Log one single-day entry. Returns its id.
  Future<String> log(String uid, TrackedEntry entry) async {
    final ref = _entries(uid).doc();
    await ref.set({
      ...entry.toCreateMap(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  /// Log a multi-day span as N single-day entries in one atomic batch — the
  /// data-side of the "one entry per day" rule. Each [DayShare] must already be
  /// a valid single-day amount (see [apportionAcrossDays]); a share out of range
  /// is rejected by the rules and by [TrackedEntry]'s own invariant.
  ///
  /// [taskName] and the optional [sourceItemId] are shared across every day's
  /// entry; the range is intentionally NOT carried (a multi-day span has no one
  /// wall-clock window).
  Future<void> logAcrossDays(
    String uid, {
    required String taskName,
    required List<DayShare> shares,
    String? sourceItemId,
  }) async {
    final batch = _db.batch();
    for (final share in shares) {
      final entry = TrackedEntry(
        id: '',
        taskName: taskName,
        durationMinutes: share.minutes,
        logDate: share.logDate,
        sourceItemId: sourceItemId,
      );
      batch.set(_entries(uid).doc(), {
        ...entry.toCreateMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  /// Edit an existing entry (owner's own). Rewrites the whole payload; the rules
  /// require the full valid key set on update too.
  Future<void> update(String uid, TrackedEntry entry) {
    return _entries(uid).doc(entry.id).set({
      ...entry.toCreateMap(),
      if (entry.createdAt != null)
        'createdAt': Timestamp.fromDate(entry.createdAt!),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> delete(String uid, String entryId) =>
      _entries(uid).doc(entryId).delete();

  /// All of the user's entries, newest logged day first. Powers future stats and
  /// a future tracked-time list; nothing reads it yet.
  Stream<List<TrackedEntry>> watch(String uid) {
    return _entries(uid)
        .orderBy('logDate', descending: true)
        .snapshots()
        .map((s) => s.docs.map(TrackedEntry.fromDoc).toList());
  }

  /// Whether an entry already exists for [sourceItemId] — the dedup seam the
  /// Done hook uses so marking a plan Done twice does not double-log it.
  Future<bool> hasEntryForItem(String uid, String sourceItemId) async {
    final q = await _entries(uid)
        .where('sourceItemId', isEqualTo: sourceItemId)
        .limit(1)
        .get();
    return q.docs.isNotEmpty;
  }
}
