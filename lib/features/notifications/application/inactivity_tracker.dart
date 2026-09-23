import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/inactivity_repository.dart';

final inactivityRepositoryProvider = Provider<InactivityRepository>((ref) {
  return FirestoreInactivityRepository(FirebaseFirestore.instance);
});

final inactivityTrackerProvider = Provider<InactivityTracker>((ref) {
  final tracker = InactivityTracker(ref.watch(inactivityRepositoryProvider));
  ref.onDispose(tracker.dispose);
  return tracker;
});

/// Coalesces frequent taps into at most one Firestore write every five minutes.
///
/// The first activity is persisted immediately. Activity during the quiet
/// interval is retained and written at its end, using the time the interaction
/// actually happened (not the later flush time). This keeps a continuously used
/// app from looking inactive without writing once per pointer event.
class InactivityTracker {
  InactivityTracker(
    this._repository, {
    DateTime Function()? now,
    this.writeInterval = const Duration(minutes: 5),
  }) : _now = now ?? DateTime.now;

  final InactivityRepository _repository;
  final DateTime Function() _now;
  final Duration writeInterval;

  String? _uid;
  DateTime? _lastWriteStartedAt;
  DateTime? _pendingActivityAt;
  Timer? _timer;

  void record(String uid) {
    final at = _now().toUtc();
    if (_uid != uid) {
      _timer?.cancel();
      _uid = uid;
      _lastWriteStartedAt = null;
      _pendingActivityAt = null;
    }

    final last = _lastWriteStartedAt;
    if (last == null || at.difference(last) >= writeInterval) {
      _timer?.cancel();
      _pendingActivityAt = null;
      _persist(uid, at);
      return;
    }

    _pendingActivityAt = at;
    _timer ??= Timer(last.add(writeInterval).difference(at), _flushPending);
  }

  void clear() {
    _timer?.cancel();
    _timer = null;
    _uid = null;
    _lastWriteStartedAt = null;
    _pendingActivityAt = null;
  }

  void _flushPending() {
    _timer = null;
    final uid = _uid;
    final at = _pendingActivityAt;
    _pendingActivityAt = null;
    if (uid != null && at != null) _persist(uid, at);
  }

  void _persist(String uid, DateTime at) {
    _lastWriteStartedAt = at;
    unawaited(
      _repository.recordActivity(uid, at).catchError((Object error) {
        // Inactivity prompts are best-effort and must never interrupt normal app
        // use. A later tap/resume starts another write interval and self-heals.
        debugPrint('InactivityTracker: activity write failed: $error');
      }),
    );
  }

  void dispose() {
    _timer?.cancel();
  }
}
