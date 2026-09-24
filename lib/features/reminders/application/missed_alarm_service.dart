// Named public collaborators keep call sites legible; private initializing
// formals would expose unusable `_store:`-style parameter names.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../notifications/application/outcome_notifier.dart';
import '../../scheduling/application/item_lapse_policy.dart';
import '../../scheduling/data/schedule_repository.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../data/alarm_lifecycle_store.dart';
import '../data/alarm_timeline_repository.dart';

const kMissedAlarmSkipReason = kUserUnavailableSkipReason;

abstract interface class MissedAlarmOutcomeRepository {
  Future<bool> markSkippedIfUnsettled(
    String targetUid,
    String itemId, {
    required String reason,
    required DateTime atUtc,
  });

  Future<bool> replaceAutomaticSkipIfMatches(
    String targetUid,
    String itemId, {
    required String expectedReason,
    required String reason,
    required DateTime atUtc,
  });

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
  Future<bool> markSkippedIfUnsettled(
    String targetUid,
    String itemId, {
    required String reason,
    required DateTime atUtc,
  }) => _repository.markSkippedIfUnsettled(
    targetUid,
    itemId,
    reason: reason,
    atUtc: atUtc,
  );

  @override
  Future<bool> replaceAutomaticSkipIfMatches(
    String targetUid,
    String itemId, {
    required String expectedReason,
    required String reason,
    required DateTime atUtc,
  }) => _repository.replaceAutomaticSkipIfMatches(
    targetUid,
    itemId,
    expectedReason: expectedReason,
    reason: reason,
    atUtc: atUtc,
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

/// Reconciles native one-minute timeouts into shared outcomes and review UI.
class MissedAlarmService extends ChangeNotifier {
  MissedAlarmService({
    required AlarmLifecycleStore store,
    required MissedAlarmOutcomeRepository outcomes,
    required AlarmTimelineRepository timeline,
    required NotificationEventNotifier notifier,
  }) : _store = store,
       _outcomes = outcomes,
       _timeline = timeline,
       _notifier = notifier;

  final AlarmLifecycleStore _store;
  final MissedAlarmOutcomeRepository _outcomes;
  final AlarmTimelineRepository _timeline;
  final NotificationEventNotifier _notifier;

  Future<void> _queue = Future.value();
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

      if (item.status != ScheduleItemStatus.approved) {
        await _store.remove(event.key);
        continue;
      }

      var outcomeRecorded = event.outcomeRecorded;
      final existingOutcome = item.outcome;
      if (existingOutcome == null && !outcomeRecorded) {
        final recorded = await _outcomes.markSkippedIfUnsettled(
          uid,
          item.id,
          reason: kMissedAlarmSkipReason,
          atUtc: event.occurredAtUtc,
        );
        // A concurrent manual outcome won. Wait for the item stream to reveal
        // which outcome it was; never guess and overwrite it.
        if (!recorded) continue;
        await _store.markOutcomeRecorded(event.key);
        outcomeRecorded = true;
      } else if (existingOutcome != null && !outcomeRecorded) {
        if (existingOutcome.result == OutcomeResult.skipped &&
            existingOutcome.skipReason == kLapsedSkipReason) {
          final replaced = await _outcomes.replaceAutomaticSkipIfMatches(
            uid,
            item.id,
            expectedReason: kLapsedSkipReason,
            reason: kMissedAlarmSkipReason,
            atUtc: event.occurredAtUtc,
          );
          if (!replaced) continue;
          await _store.markOutcomeRecorded(event.key);
          outcomeRecorded = true;
        } else if (existingOutcome.result == OutcomeResult.done &&
            event.reviewChoice == MissedAlarmReviewChoice.done) {
          outcomeRecorded = true;
        } else if (existingOutcome.result != OutcomeResult.skipped ||
            existingOutcome.skipReason != kMissedAlarmSkipReason) {
          // A manual Done/Skip won the race. Never overwrite the person's
          // outcome, but the independent timeout fact still happened and must
          // survive before the native row is removed.
          await _timeline.recordUnavailable(uid, item.id, event.occurredAtUtc);
          await _store.remove(event.key);
          continue;
        } else {
          await _store.markOutcomeRecorded(event.key);
          outcomeRecorded = true;
        }
      }

      if (event.reviewChoice == MissedAlarmReviewChoice.done &&
          existingOutcome?.result != OutcomeResult.done) {
        if (existingOutcome == null) {
          // The local item stream can briefly lag both the automatic Skip and
          // the subsequent Done transaction. Wait for its authoritative state
          // instead of issuing the correction twice against stale input.
          continue;
        }
        if (existingOutcome.result != OutcomeResult.skipped ||
            existingOutcome.skipReason != kMissedAlarmSkipReason) {
          // A different manual outcome won on another client. Preserve the
          // independent alarm-time fact, but never overwrite that choice.
          await _timeline.recordUnavailable(uid, item.id, event.occurredAtUtc);
          await _store.remove(event.key);
          continue;
        }
        // Legacy rows may have the automatic skip but not the independent
        // timeline fact yet. Persist that fact before the rules permit the
        // correction to Done.
        await _timeline.recordUnavailable(uid, item.id, event.occurredAtUtc);
        final changed = await _outcomes.replaceMissedAlarmSkipWithDone(
          uid,
          item.id,
          plannerUid: item.createdByUid,
        );
        if (!changed) continue;
      }

      if (!event.reviewed && outcomeRecorded) {
        reviews.add(MissedAlarmReview(event: event, item: item));
        // The popup is a local review surface. Publish it as soon as the
        // durable outcome exists; planner push delivery must not sit on its
        // critical path (it can take two independent 10-second timeouts).
        _setReviews(reviews);
      }

      if (existingOutcome?.result == OutcomeResult.skipped &&
          existingOutcome?.skipReason == kMissedAlarmSkipReason &&
          item.alarm?.unavailableAt == null) {
        // Compatibility for timeout rows created before unavailableAt became a
        // separate shared fact. The review is already visible above, so this
        // repair does not reintroduce the popup delay.
        await _timeline.recordUnavailable(uid, item.id, event.occurredAtUtc);
      }

      if (outcomeRecorded) {
        if (event.reviewChoice == MissedAlarmReviewChoice.done) {
          if (!event.reviewNotificationDelivered) {
            unawaited(_deliverDoneFollowUp(event, item, uid));
          } else if (event.notificationDelivered) {
            await _store.remove(event.key);
          }
        } else if (!event.notificationDelivered) {
          unawaited(_deliverAutomaticOutcome(event, item, uid));
        } else if (event.reviewed) {
          await _store.remove(event.key);
        }
      }
    }
    reviews.sort(
      (a, b) => a.event.occurredAtUtc.compareTo(b.event.occurredAtUtc),
    );
    _setReviews(reviews);
  }

  Future<void> markDone(MissedAlarmReview review) async {
    await _store.markReviewChoice(
      review.event.key,
      MissedAlarmReviewChoice.done,
    );
    _setReviews([
      for (final candidate in _reviews)
        if (candidate.event.key != review.event.key) candidate,
    ]);
    await _timeline.recordUnavailable(
      review.item.targetUid,
      review.item.id,
      review.event.occurredAtUtc,
    );
    final changed = await _outcomes.replaceMissedAlarmSkipWithDone(
      review.item.targetUid,
      review.item.id,
      plannerUid: review.item.createdByUid,
    );
    if (changed) {
      await _deliverDoneFollowUp(
        review.event,
        review.item,
        review.item.targetUid,
      );
    }
    await resync();
  }

  Future<void> markSkipped(MissedAlarmReview review) async {
    await _store.markReviewChoice(
      review.event.key,
      MissedAlarmReviewChoice.skipped,
    );
    _setReviews([
      for (final candidate in _reviews)
        if (candidate.event.key != review.event.key) candidate,
    ]);
    await resync();
  }

  Future<void> _deliverAutomaticOutcome(
    AlarmLifecycleEvent event,
    ScheduleItem item,
    String uid,
  ) async {
    if (item.createdByUid == uid) {
      await _store.markNotificationDelivered(event.key);
      await resync();
      return;
    }
    final result = await _notifier.notifyConfirmed(
      event: NotifyEvent.outcome,
      targetUid: uid,
      itemId: item.id,
    );
    if (result.delivered || result.reason == 'already-notified') {
      await _store.markNotificationDelivered(event.key);
      await resync();
    }
  }

  Future<void> _deliverDoneFollowUp(
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
