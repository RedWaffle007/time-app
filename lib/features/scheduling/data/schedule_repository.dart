import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/timezone/tz_resolver.dart';
import '../../celebrations/domain/completion_celebration.dart';
import '../domain/schedule_item.dart';

/// Creates schedule items and drives their status/outcome transitions.
class ScheduleRepository {
  ScheduleRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _items(String targetUid) =>
      _db.collection('scheduleItems').doc(targetUid).collection('items');

  /// Creates an item. [wall] is the wall-clock time as entered; it's resolved to
  /// a UTC instant using the target's [timezone].
  ///
  /// Two callers:
  ///   • a planner planning for someone else — [groupId] names the granting
  ///     group and [status] stays `pending` (the target approves per item).
  ///   • a user planning for themselves — [groupId] is null (no group needed)
  ///     and [status] is `approved` (self-authored items skip the queue).
  /// The rules enforce that only the self path may create an `approved` item.
  /// Returns the new item's id so the caller can fire the `created` push
  /// (planner path only — self-planned items have no one to notify).
  Future<String> createItem({
    required String targetUid,
    required String createdByUid,
    String? groupId,
    required String title,
    String? note,
    required DateTime wall,
    required String timezone,
    ScheduleItemStatus status = ScheduleItemStatus.pending,
    ItemTier tier = ItemTier.normal,
    int durationMinutes = 0,
    String? planRequestId,
    // Voice-note alarms (item 32b): the id the audio was uploaded under, and
    // the metadata the Worker returned. The rules accept the note only if it
    // matches the Worker's own upload record for this id.
    String? itemId,
    VoiceNoteMeta? voiceNote,
  }) async {
    final instant = resolveWallTimeToUtc(wall, timezone);

    final itemRef = _items(targetUid).doc(itemId);
    // Items are point-in-time alarms, not 30-minute appointments: the model has
    // no duration. Multiple plans may therefore share a half-hour (or even the
    // same instant). The old scheduleSlots write is intentionally gone; the
    // the authorized stream is projected into day conflict times, never a lock.
    await itemRef.set({
      'targetUid': targetUid,
      'createdByUid': createdByUid,
      'groupId': groupId ?? '',
      'title': sanitizeScheduleTitle(title),
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      'localWallTime': formatWallTime(wall),
      'timezone': timezone,
      'scheduledInstantUtc': Timestamp.fromDate(instant),
      'status': status.name,
      // Only stamped when non-default, so pre-#5 items and every normal item
      // stay byte-identical to before; the rules default an absent tier to
      // 'normal'. An emergency item is created already-`approved` (skips the
      // queue) — the caller sets that status.
      if (tier != ItemTier.normal) 'tier': tier.name,
      if (durationMinutes > 0) 'durationMinutes': durationMinutes,
      'planRequestId': ?planRequestId,
      if (voiceNote != null) 'voiceNote': voiceNote.toCreateMap(),
      // A self-approved item is decided at creation — record it for parity with
      // the approve() transition.
      if (status == ScheduleItemStatus.approved)
        'decidedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return itemRef.id;
  }

  /// The TARGET's delivery receipt for a voice note (item 32c): stamped once,
  /// after a verified copy is on their phone. The rules allow only this field.
  Future<void> markVoiceNoteDelivered(String targetUid, String itemId) =>
      _items(targetUid).doc(itemId).update({
        'voiceNote.deliveredAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  /// A fresh item id for [targetUid], minted BEFORE the item exists so a voice
  /// note can be uploaded under it first (item 32b).
  String newItemId(String targetUid) => _items(targetUid).doc().id;

  /// **Group planning — the fan-out** (pairwise friendships cannot do this).
  ///
  /// Creates the SAME plan (title/time/note) for every [targets] entry, each
  /// resolved in THAT member's own home timezone — so "9am" means 9am locally
  /// for each person, not one absolute instant. It is a plain loop of
  /// [createItem], so every write goes through the exact same authorization and
  /// slot lock; there is no new rule and no batch (a member's failure — a taken
  /// slot, a missing grant, a past time — must not sink everyone else's plan).
  ///
  /// The planner themselves (`isSelf`) is created `approved`; every other member
  /// is `pending` for their own approval, unchanged from single planning. A
  /// target whose resolved instant is already in the past is skipped, matching
  /// the builder's past guard.
  ///
  /// Returns the items actually created (uid + id + isSelf, so the caller can
  /// fire the per-member `created` push) and the skip counts, split so the UI
  /// can say WHY nobody got planned: [skippedPast] (the chosen time is already
  /// gone in that member's zone) versus [skippedOther] (a taken slot, a missing
  /// grant, any write failure).
  Future<
    ({
      List<({String uid, String itemId, bool isSelf})> sent,
      int skippedPast,
      int skippedOther,
    })
  >
  planForGroup({
    required String groupId,
    required String createdByUid,
    required List<({String uid, String timezone, bool isSelf})> targets,
    required String title,
    String? note,
    required DateTime wall,
    // An EMERGENCY group plan (item 15): every copy is born approved and
    // skips the queue; the rules require each member's own emergency grant.
    ItemTier tier = ItemTier.normal,
  }) async {
    final sent = <({String uid, String itemId, bool isSelf})>[];
    final emergency = tier == ItemTier.emergency;
    var skippedPast = 0;
    var skippedOther = 0;
    final now = DateTime.now().toUtc();
    for (final t in targets) {
      if (!resolveWallTimeToUtc(wall, t.timezone).isAfter(now)) {
        skippedPast++;
        continue;
      }
      try {
        final id = await createItem(
          targetUid: t.uid,
          createdByUid: createdByUid,
          groupId: t.isSelf ? null : groupId,
          title: title,
          note: note,
          wall: wall,
          timezone: t.timezone,
          status: t.isSelf || emergency
              ? ScheduleItemStatus.approved
              : ScheduleItemStatus.pending,
          tier: tier,
        );
        sent.add((uid: t.uid, itemId: id, isSelf: t.isSelf));
      } catch (_) {
        // Best-effort: a taken slot or any per-member failure is skipped, never
        // fatal to the rest of the fan-out.
        skippedOther++;
      }
    }
    return (sent: sent, skippedPast: skippedPast, skippedOther: skippedOther);
  }

  /// All items belonging to a target (they filter by status in the UI).
  Stream<List<ScheduleItem>> watchItemsForTarget(String targetUid) {
    return _items(
      targetUid,
    ).snapshots().map((s) => s.docs.map(ScheduleItem.fromDoc).toList());
  }

  /// All items a planner created, across targets — powers their activity view.
  Stream<List<ScheduleItem>> watchItemsByPlanner(String plannerUid) {
    return _db
        .collectionGroup('items')
        .where('createdByUid', isEqualTo: plannerUid)
        .snapshots()
        .map((s) => s.docs.map(ScheduleItem.fromDoc).toList());
  }

  // --- transitions ---

  Future<void> _setStatus(
    String targetUid,
    String itemId,
    ScheduleItemStatus status, {
    Map<String, dynamic> extra = const {},
  }) {
    return _items(targetUid).doc(itemId).set({
      'status': status.name,
      'updatedAt': FieldValue.serverTimestamp(),
      ...extra,
    }, SetOptions(merge: true));
  }

  Future<void> approve(String targetUid, String itemId) => _setStatus(
    targetUid,
    itemId,
    ScheduleItemStatus.approved,
    extra: {'decidedAt': FieldValue.serverTimestamp()},
  );

  /// Planner withdraws a plan they created, BEFORE the target has decided on it
  /// (Group C). Only a `pending` item can be withdrawn; the field set here must
  /// match exactly what the withdraw branch of firestore.rules permits (status,
  /// withdrawnAt, updatedAt) — the planner is not the target, so this is the one
  /// item write a non-target is allowed, and it is tightly scoped.
  Future<void> withdraw(
    String targetUid,
    String itemId, {
    ScheduleItem? item,
  }) async {
    await _items(targetUid).doc(itemId).set({
      'status': ScheduleItemStatus.withdrawn.name,
      'withdrawnAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> reject(
    String targetUid,
    String itemId, {
    String? reason,
    ScheduleItem? item,
  }) async {
    await _setStatus(
      targetUid,
      itemId,
      ScheduleItemStatus.rejected,
      extra: {
        'decidedAt': FieldValue.serverTimestamp(),
        if (reason != null && reason.trim().isNotEmpty)
          'rejectionReason': reason.trim(),
      },
    );
  }

  /// Target records completion — status stays `approved`, outcome is layered on.
  Future<bool> markDone(
    String targetUid,
    String itemId, {
    required String plannerUid,
  }) async {
    final itemRef = _items(targetUid).doc(itemId);
    final eventId = CompletionCelebration.eventId(targetUid, itemId);
    final eventRef = _db.collection('completionCelebrations').doc(eventId);
    final participants = <String>{targetUid, plannerUid}.toList();
    return _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(itemRef);
      final data = snapshot.data();
      if (data == null ||
          data['status'] != ScheduleItemStatus.approved.name ||
          data['outcome'] != null) {
        return false;
      }
      transaction.update(itemRef, {
        'outcome': {
          'result': OutcomeResult.done.name,
          'completedAt': FieldValue.serverTimestamp(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      });
      transaction.set(eventRef, {
        'itemId': itemId,
        'targetUid': targetUid,
        'plannerUid': plannerUid,
        'participantUids': participants,
        'seenByUids': <String>[],
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
  }

  Future<bool> markSkipped(
    String targetUid,
    String itemId, {
    String? reason,
    String? announceToPlannerUid,
  }) => markSkippedIfUnsettled(
    targetUid,
    itemId,
    reason: reason?.trim() ?? '',
    announceToPlannerUid: announceToPlannerUid,
  );

  /// Timeout-only outcome write. Unlike the interactive Skip action, this can
  /// race a person pressing Done, so it must prove `outcome` is still absent in
  /// the same transaction that writes the automatic skip.
  Future<bool> markSkippedIfUnsettled(
    String targetUid,
    String itemId, {
    required String reason,
    DateTime? atUtc,
    // A person's own Skip (card or missed-alarm review) tells a planner who is
    // someone else, via the durable pop-up record written in this same
    // transaction. Automatic lapses pass null: the Worker announces those.
    String? announceToPlannerUid,
  }) async {
    final ref = _items(targetUid).doc(itemId);
    final announce =
        announceToPlannerUid != null &&
        announceToPlannerUid.isNotEmpty &&
        announceToPlannerUid != targetUid;
    final eventRef = _db
        .collection('completionCelebrations')
        .doc(CompletionCelebration.skippedEventId(targetUid, itemId));
    return _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      final data = snapshot.data();
      if (data == null ||
          data['status'] != ScheduleItemStatus.approved.name ||
          data['outcome'] != null) {
        return false;
      }
      transaction.update(ref, {
        'outcome': {
          'result': OutcomeResult.skipped.name,
          'skippedAt': atUtc == null
              ? FieldValue.serverTimestamp()
              : Timestamp.fromDate(atUtc),
          if (reason.trim().isNotEmpty) 'skipReason': reason.trim(),
        },
        // The alarm-time fact is immutable once present (rules compare it);
        // stamp it only when this skip is the first evidence of it.
        if (reason.trim() == kUserUnavailableSkipReason &&
            (data['alarm'] as Map?)?['unavailableAt'] == null)
          'alarm.unavailableAt': atUtc == null
              ? FieldValue.serverTimestamp()
              : Timestamp.fromDate(atUtc.toUtc()),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (announce && data['createdByUid'] == announceToPlannerUid) {
        transaction.set(eventRef, {
          'itemId': itemId,
          'targetUid': targetUid,
          'plannerUid': announceToPlannerUid,
          'participantUids': [announceToPlannerUid],
          'seenByUids': <String>[],
          'createdAt': FieldValue.serverTimestamp(),
          'result': 'skipped',
        });
      }
      return true;
    });
  }

  /// The one settled-outcome correction the missed-alarm review permits. The
  /// task outcome becomes Done, while `alarm.unavailableAt` remains untouched
  /// as the permanent response-time fact. A completion celebration is created
  /// atomically, exactly as in the ordinary first-write Done path.
  Future<bool> replaceMissedAlarmSkipWithDone(
    String targetUid,
    String itemId, {
    required String plannerUid,
  }) async {
    final itemRef = _items(targetUid).doc(itemId);
    final eventId = CompletionCelebration.eventId(targetUid, itemId);
    final eventRef = _db.collection('completionCelebrations').doc(eventId);
    final participants = <String>{targetUid, plannerUid}.toList();
    return _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(itemRef);
      final data = snapshot.data();
      final outcome = data?['outcome'];
      final alarm = data?['alarm'];
      if (data == null ||
          data['status'] != ScheduleItemStatus.approved.name ||
          outcome is! Map ||
          outcome['result'] != OutcomeResult.skipped.name ||
          outcome['skipReason'] != kUserUnavailableSkipReason ||
          alarm is! Map ||
          alarm['unavailableAt'] is! Timestamp) {
        return false;
      }
      transaction.update(itemRef, {
        'outcome': {
          'result': OutcomeResult.done.name,
          'completedAt': FieldValue.serverTimestamp(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      });
      transaction.set(eventRef, {
        'itemId': itemId,
        'targetUid': targetUid,
        'plannerUid': plannerUid,
        'participantUids': participants,
        'seenByUids': <String>[],
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
  }
}
