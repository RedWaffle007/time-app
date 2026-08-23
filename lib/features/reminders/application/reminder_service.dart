// The constructor takes NAMED collaborators, so the initializing formal the lint
// wants (`required this._scheduler`) would put a private name in the public API
// and force every call site to write `_scheduler:`. Same call as
// `app_lock_controller.dart` made: the initializer list is correct here.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../scheduling/domain/schedule_item.dart';
import '../data/reminder_audit_log.dart';
import '../data/reminder_mirror_store.dart';
import '../data/reminder_scheduler.dart';
import '../domain/reminder.dart';
import 'reminder_policy.dart';
import 'reminder_reconciler.dart';

/// Applies the reconciler's plan to the OS and the mirror. The only stateful
/// piece of the reminder layer, and deliberately thin: it owns sequencing and
/// nothing else — every decision was already made by [desiredReminders] and
/// [reconcileReminders], where it can be tested.
///
/// **Everything runs through one serialized queue.** The three triggers (the
/// item stream emitting, app start, app resume) can and do overlap: a resume
/// while a stream emission is mid-flight would otherwise have two passes reading
/// the same mirror, each computing a plan against a state the other is about to
/// change, and the loser's writes would be silently lost. Chaining onto a single
/// future makes every pass see the previous pass's result. It costs nothing —
/// the common pass is a no-op that touches no plugin at all.
class ReminderService {
  ReminderService({
    required ReminderScheduler scheduler,
    required ReminderMirrorStore store,
    ReminderAuditLog audit = const ReminderAuditLog(),
  })  : _scheduler = scheduler,
        _store = store,
        _audit = audit;

  final ReminderScheduler _scheduler;
  final ReminderMirrorStore _store;
  final ReminderAuditLog _audit;

  Future<void> _queue = Future<void>.value();
  bool _initialized = false;

  /// The last uid we scheduled for, so an account switch can be told apart from
  /// an ordinary re-emission. Null means nobody is signed in.
  String? _uid;

  /// Serializes [action] behind everything already queued. Failures are
  /// contained: a broken pass must not poison the chain and stop every later
  /// reconcile, which would turn one transient error into permanently dead
  /// reminders — the exact shape of the `_registeredUid` latch bug
  /// (DECISIONS.md 2026-07-24).
  Future<void> _enqueue(Future<void> Function() action) {
    final next = _queue.then((_) => action()).catchError((Object e, StackTrace st) {
      debugPrint('ReminderService: pass failed: $e');
    });
    _queue = next;
    return next;
  }

  Future<void> initialize() => _enqueue(() async {
        if (_initialized) return;
        await _scheduler.initialize();
        _initialized = true;
      });

  /// Brings the OS in line with [items] for [uid]. Idempotent — call it as often
  /// as you like.
  ///
  /// [reason] only reaches the audit CSV, and only when something actually
  /// changed. It is what makes a row in that file legible six weeks later:
  /// "armed at 04:51" is much less useful than "armed at 04:51 because the app
  /// resumed".
  Future<void> sync({
    required List<ScheduleItem> items,
    required String? uid,
    String reason = 'sync',
  }) =>
      _enqueue(() async {
        // An account change invalidates the entire local state: the previous
        // user's reminders must not fire into this user's session, and their ids
        // must not be reused. Done before anything else so the reconcile below
        // starts from a clean mirror. (Sign-out arrives here as uid == null.)
        if (uid != _uid) {
          await _scheduler.cancelAll();
          await _store.clear();
          _uid = uid;
          _audit.note(event: 'ACCOUNT_CHANGED', note: reason);
        }
        if (uid == null) return;

        final now = DateTime.now().toUtc();
        final desired = desiredReminders(items: items, uid: uid, now: now);
        final mirror = await _store.load();
        final plan = reconcileReminders(
          desired: desired,
          mirror: mirror,
          now: now,
        );

        if (plan.isEmpty) return; // the common case: nothing to do, nothing said

        _audit.note(
          event: 'RECONCILE',
          note: '$reason schedule=${plan.toSchedule.length} '
              'cancel=${plan.toCancel.length} live=${plan.mirror.length}',
        );

        // Cancel first. If an item's id were somehow being reassigned in the
        // same pass, scheduling before cancelling would arm it and then
        // immediately throw it away.
        for (final id in plan.toCancel) {
          await _scheduler.cancel(id);
        }

        // A reminder the OS refused is kept OUT of the mirror rather than
        // recorded as scheduled. Recording it would make the next reconcile
        // believe it exists and never retry — a reminder lost permanently and
        // silently, which is this layer's worst failure mode. Left out, it is
        // simply re-attempted on the next pass, so granting the exact-alarm
        // permission and returning to the app repairs it with no extra code.
        final refused = <String>{};
        for (final action in plan.toSchedule) {
          final ok = await _scheduler.schedule(action.request, action.notificationId);
          if (!ok) refused.add(action.request.itemId);
        }

        await _store.save([
          for (final m in plan.mirror)
            if (!refused.contains(m.itemId)) m,
        ]);
      });

  /// Sign-out. Drops every scheduled reminder and the mirror with it.
  Future<void> clearAll() => sync(items: const [], uid: null, reason: 'clear');

  /// Silence and clear the alarm notification for [itemId] — the alarm screen's
  /// Dismiss. FLAG_INSISTENT loops the tone until the notification is cancelled,
  /// so this is what stops the sound.
  ///
  /// It cancels the OS notification but does NOT touch the mirror: the reminder
  /// has already fired, so on the next reconcile its instant is in the past,
  /// `desiredReminders` drops it, and the mirror row is cleaned up there. Doing
  /// it here too would just be a second place deciding the same thing.
  ///
  /// The id is the one the mirror recorded (the authority, since a collision may
  /// have moved it off the bare hash); the hash is the fallback for the case
  /// where the mirror was wiped — a dismiss must still be able to silence a
  /// notification it can no longer look up.
  Future<void> dismiss(String itemId) => _enqueue(() async {
        final mirror = await _store.load();
        int? id;
        for (final m in mirror) {
          if (m.itemId == itemId) {
            id = m.notificationId;
            break;
          }
        }
        await _scheduler.cancel(id ?? reminderNotificationId(itemId));
      });

  /// What the app currently believes is scheduled — for the diagnostics screen
  /// only. Nothing in the scheduling path reads this.
  Future<List<ScheduledReminder>> debugMirror() => _store.load();
}
