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

const kMissedAlarmSkipReason = 'User unavailable';

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

      if (event.kind == AlarmLifecycleEventKind.volumeSilenced) {
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
        } else if (existingOutcome.result != OutcomeResult.skipped ||
            existingOutcome.skipReason != kMissedAlarmSkipReason) {
          // A manual Done/Skip won the race. Never overwrite a user's outcome.
          await _store.remove(event.key);
          continue;
        } else {
          await _store.markOutcomeRecorded(event.key);
          outcomeRecorded = true;
        }
      }

      var notificationDelivered = event.notificationDelivered;
      if (outcomeRecorded && !notificationDelivered) {
        if (item.createdByUid == uid) {
          await _store.markNotificationDelivered(event.key);
          notificationDelivered = true;
        } else {
          final result = await _notifier.notifyConfirmed(
            event: NotifyEvent.outcome,
            targetUid: uid,
            itemId: item.id,
          );
          if (result.delivered || result.reason == 'already-notified') {
            await _store.markNotificationDelivered(event.key);
            notificationDelivered = true;
          }
        }
      }

      if (event.reviewed) {
        if (notificationDelivered) await _store.remove(event.key);
      } else if (outcomeRecorded) {
        reviews.add(MissedAlarmReview(event: event, item: item));
      }
    }
    reviews.sort(
      (a, b) => a.event.occurredAtUtc.compareTo(b.event.occurredAtUtc),
    );
    _setReviews(reviews);
  }

  Future<void> markReviewed(MissedAlarmReview review) async {
    await _store.markReviewed(review.event.key);
    _setReviews([
      for (final candidate in _reviews)
        if (candidate.event.key != review.event.key) candidate,
    ]);
    if (review.event.notificationDelivered ||
        review.item.createdByUid == review.item.targetUid) {
      await _store.remove(review.event.key);
    }
  }

  Future<void> markAllReviewed() async {
    for (final review in List<MissedAlarmReview>.of(_reviews)) {
      await markReviewed(review);
    }
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
