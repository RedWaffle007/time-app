// Named public collaborators keep call sites legible; private initializing
// formals would expose unusable `_store:`-style parameter names.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../notifications/application/outcome_notifier.dart';
import '../../scheduling/data/schedule_repository.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../data/alarm_lifecycle_store.dart';
import '../data/alarm_timeline_repository.dart';

/// The skip reason a person's own "Mark as Skipped" review choice records.
const kMissedAlarmSkipReason = kUserUnavailableSkipReason;

abstract interface class MissedAlarmOutcomeRepository {
  /// First-write-wins Done, chosen by the person in the review.
  Future<bool> markDoneIfUnsettled(
    String targetUid,
    String itemId, {
    required String plannerUid,
  });

  /// First-write-wins Skip, chosen by the person in the review. A non-null
  /// [plannerUid] (someone else) gets the in-app Skip pop-up.
  Future<bool> markSkippedIfUnsettled(
    String targetUid,
    String itemId, {
    required String reason,
    String? plannerUid,
  });

  /// Legacy correction: builds before 2026-09-25 wrote an automatic
  /// `Skipped: User unavailable` at the timeout; the review may still turn
  /// exactly that record into Done.
  Future<bool> replaceMissedAlarmSkipWithDone(
    String targetUid,
    String itemId, {
    required String plannerUid,
  });
}

class ScheduleMissedAlarmOutcomeRepository
    implements MissedAlarmOutcomeRepository {
  ScheduleMissedAlarmOutcomeRepository(this._repository);

  final ScheduleRepository _repository;

  @override
  Future<bool> markDoneIfUnsettled(
    String targetUid,
    String itemId, {
    required String plannerUid,
  }) => _repository.markDone(targetUid, itemId, plannerUid: plannerUid);

  @override
  Future<bool> markSkippedIfUnsettled(
    String targetUid,
    String itemId, {
    required String reason,
    String? plannerUid,
  }) => _repository.markSkippedIfUnsettled(
    targetUid,
    itemId,
    reason: reason,
    announceToPlannerUid: plannerUid,
  );

  @override
  Future<bool> replaceMissedAlarmSkipWithDone(
    String targetUid,
    String itemId, {
    required String plannerUid,
  }) => _repository.replaceMissedAlarmSkipWithDone(
    targetUid,
    itemId,
    plannerUid: plannerUid,
  );
}

class MissedAlarmReview {
  const MissedAlarmReview({required this.event, required this.item});

  final AlarmLifecycleEvent event;
  final ScheduleItem item;
}

/// Whether [outcome] is the automatic skip an older build wrote at timeout.
bool _isLegacyAutomaticSkip(ScheduleOutcome? outcome) =>
    outcome?.result == OutcomeResult.skipped &&
    outcome?.skipReason == kMissedAlarmSkipReason;

/// Reconciles native one-minute timeouts into the shared alarm-time fact and
/// the review UI.
///
/// A timeout records ONLY `alarm.unavailableAt` — the permanent "User
/// unavailable at alarm time" fact. It never writes a task outcome: the task
/// stays undecided in My Schedule until the person chooses Done or Skipped
/// (here, on the card, on another device) or the end-of-day lapse settles it.
/// (DECISIONS.md "Missed alarm — tag only, decision stays with the person".)
///
/// The native event's `outcomeRecorded` flag means "the unavailable fact is
/// persisted". Rows written by older builds carry an automatic Skipped outcome;
/// they are still offered for review and may be corrected to Done.
class MissedAlarmService extends ChangeNotifier {
  MissedAlarmService({
    required AlarmLifecycleStore store,
    required MissedAlarmOutcomeRepository outcomes,
    required AlarmTimelineRepository timeline,
    required NotificationEventNotifier notifier,
    // Item 32c-2: records the fallback fact and tells the planner. Returns
    // true once the fact is stored, so the native event can be dropped.
    Future<bool> Function(String uid, String itemId, DateTime atUtc)?
    reportVoiceFallback,
  }) : _store = store,
       _outcomes = outcomes,
       _timeline = timeline,
       _notifier = notifier,
       _reportVoiceFallback = reportVoiceFallback;

  final Future<bool> Function(String uid, String itemId, DateTime atUtc)?
  _reportVoiceFallback;

  final AlarmLifecycleStore _store;
  final MissedAlarmOutcomeRepository _outcomes;
  final AlarmTimelineRepository _timeline;
  final NotificationEventNotifier _notifier;

  Future<void> _queue = Future.value();
  final _persistingFacts = <String>{};
  List<MissedAlarmReview> _reviews = const [];
  List<ScheduleItem> _lastItems = const [];
  String? _lastUid;

  List<MissedAlarmReview> get reviews => _reviews;

  Future<void> sync(List<ScheduleItem> items, String? uid) {
    _lastItems = items;
    _lastUid = uid;
    final next = _queue.then((_) => _sync(items, uid)).catchError((
      Object error,
      StackTrace stack,
    ) {
      debugPrint('MissedAlarmService: sync failed: $error');
    });
    _queue = next;
    return next;
  }

  Future<void> resync() => sync(_lastItems, _lastUid);

  Future<void> _sync(List<ScheduleItem> items, String? uid) async {
    if (uid == null) {
      _setReviews(const []);
      return;
    }
    final byId = {for (final item in items) item.id: item};
    final reviews = <MissedAlarmReview>[];
    for (final event in await _store.read()) {
      final item = byId[event.itemId];
      if (item == null || item.targetUid != uid) continue;

      if (event.kind == AlarmLifecycleEventKind.dismissed) {
        await _timeline.recordDismissed(uid, item.id, event.occurredAtUtc);
        await _store.remove(event.key);
        continue;
      }

      // A voice note that could not play is a fact about the ring, not an
      // answer: record it for the planner and move on (item 32c-2). Kept
      // until reported, so an offline phone reports it on its next pass.
      if (event.kind == AlarmLifecycleEventKind.voiceFallback) {
        final report = _reportVoiceFallback;
        if (report == null ||
            await report(uid, item.id, event.occurredAtUtc)) {
          await _store.remove(event.key);
        }
        continue;
      }

      if (item.status != ScheduleItemStatus.approved) {
        await _store.remove(event.key);
        continue;
      }

      final outcome = item.outcome;
      final choice = event.reviewChoice;
      final factMissing =
          !event.outcomeRecorded || item.alarm?.unavailableAt == null;

      // 1. Undecided and unanswered: show the popup NOW. The alarm-time fact
      //    is a Firestore transaction (a server round trip, impossible
      //    offline), so it is persisted in the BACKGROUND — waiting on it was
      //    the multi-second popup delay reported 2026-09-25. A choice made
      //    before it lands persists it first (see [_applyChoice]).
      if (outcome == null && choice == null) {
        if (factMissing) _persistFactInBackground(event, uid, item.id);
        reviews.add(MissedAlarmReview(event: event, item: item));
        _setReviews(reviews);
        continue;
      }

      // Every other path may drop the native row below, so the fact is made
      // durable first. Immutable once written: a replay is a no-op.
      if (factMissing) await _persistFact(event, uid, item.id);

      // 2. A choice whose outcome write has not landed yet (offline, process
      //    death): finish it.
      if (outcome == null) {
        _retryInBackground(_applyChoice(event, item, choice!));
        continue;
      }

      // 3. Legacy: an older build auto-skipped. Its planner push may still be
      //    owed, and the person may still turn it into Done.
      if (_isLegacyAutomaticSkip(outcome)) {
        if (choice == null) {
          reviews.add(MissedAlarmReview(event: event, item: item));
          _setReviews(reviews);
          if (!event.notificationDelivered) {
            _retryInBackground(_deliverLegacyAutomaticSkip(event, item, uid));
          }
          continue;
        }
        if (choice == MissedAlarmReviewChoice.done) {
          _retryInBackground(_applyChoice(event, item, choice));
          continue;
        }
      }

      // 4. Settled. A choice made in the review still owes the planner one
      //    push; an outcome decided anywhere else was already announced there.
      if (choice != null && !event.reviewNotificationDelivered) {
        _retryInBackground(_deliverChoice(event, item, uid));
        continue;
      }
      await _store.remove(event.key);
    }
    reviews.sort(
      (a, b) => a.event.occurredAtUtc.compareTo(b.event.occurredAtUtc),
    );
    _setReviews(reviews);
  }

  /// Returns whether THIS call committed the outcome (false when another
  /// client decided first) — the caller celebrates only its own Done.
  Future<bool> markDone(MissedAlarmReview review) =>
      _choose(review, MissedAlarmReviewChoice.done);

  Future<bool> markSkipped(MissedAlarmReview review) =>
      _choose(review, MissedAlarmReviewChoice.skipped);

  Future<bool> _choose(
    MissedAlarmReview review,
    MissedAlarmReviewChoice choice,
  ) async {
    // Durable intent first, so a crash mid-write is finished on next sync.
    await _store.markReviewChoice(review.event.key, choice);
    _setReviews([
      for (final candidate in _reviews)
        if (candidate.event.key != review.event.key) candidate,
    ]);
    final changed = await _applyChoice(review.event, review.item, choice);
    await resync();
    return changed;
  }

  void _persistFactInBackground(
    AlarmLifecycleEvent event,
    String uid,
    String itemId,
  ) {
    if (!_persistingFacts.add(event.key)) return; // already in flight
    _retryInBackground(
      _persistFact(
        event,
        uid,
        itemId,
      ).whenComplete(() => _persistingFacts.remove(event.key)),
    );
  }

  Future<void> _persistFact(
    AlarmLifecycleEvent event,
    String uid,
    String itemId,
  ) async {
    await _timeline.recordUnavailable(uid, itemId, event.occurredAtUtc);
    if (!event.outcomeRecorded) await _store.markOutcomeRecorded(event.key);
  }

  /// Background retries are driven by the next item-stream emission, never by
  /// resyncing from here: a write that lost a race would otherwise spin until
  /// the stream caught up.
  void _retryInBackground(Future<void> work) {
    unawaited(
      work.catchError((Object error) {
        debugPrint('MissedAlarmService: background retry failed: $error');
      }),
    );
  }

  /// Writes the chosen outcome. First-write-wins: a Done/Skip recorded
  /// elsewhere in the meantime is never overwritten.
  Future<bool> _applyChoice(
    AlarmLifecycleEvent event,
    ScheduleItem item,
    MissedAlarmReviewChoice choice,
  ) async {
    final uid = item.targetUid;
    // The fact goes first, so a Done reads "Done (Late)" everywhere. Idempotent
    // when the background write already landed.
    await _timeline.recordUnavailable(uid, item.id, event.occurredAtUtc);
    final bool changed;
    if (choice == MissedAlarmReviewChoice.done) {
      changed = _isLegacyAutomaticSkip(item.outcome)
          ? await _outcomes.replaceMissedAlarmSkipWithDone(
              uid,
              item.id,
              plannerUid: item.createdByUid,
            )
          : await _outcomes.markDoneIfUnsettled(
              uid,
              item.id,
              plannerUid: item.createdByUid,
            );
    } else {
      changed = await _outcomes.markSkippedIfUnsettled(
        uid,
        item.id,
        reason: kMissedAlarmSkipReason,
        plannerUid: item.createdByUid,
      );
    }
    // The planner push can take two 10-second timeouts; it must not hold the
    // popup's buttons disabled for the next review.
    if (changed) _retryInBackground(_deliverChoice(event, item, uid));
    return changed;
  }

  Future<void> _deliverChoice(
    AlarmLifecycleEvent event,
    ScheduleItem item,
    String uid,
  ) async {
    if (item.createdByUid != uid) {
      final result = await _notifier.notifyConfirmed(
        event: NotifyEvent.outcome,
        targetUid: uid,
        itemId: item.id,
      );
      if (!result.delivered && result.reason != 'already-notified') return;
    }
    await _store.markNotificationDelivered(event.key);
    await _store.markReviewNotificationDelivered(event.key);
    await resync();
  }

  Future<void> _deliverLegacyAutomaticSkip(
    AlarmLifecycleEvent event,
    ScheduleItem item,
    String uid,
  ) async {
    if (item.createdByUid != uid) {
      final result = await _notifier.notifyConfirmed(
        event: NotifyEvent.outcome,
        targetUid: uid,
        itemId: item.id,
      );
      if (!result.delivered && result.reason != 'already-notified') return;
    }
    await _store.markNotificationDelivered(event.key);
  }

  void _setReviews(List<MissedAlarmReview> value) {
    if (listEquals(
      _reviews.map((review) => review.event.key).toList(),
      value.map((review) => review.event.key).toList(),
    )) {
      return;
    }
    _reviews = List.unmodifiable(value);
    notifyListeners();
  }
}
