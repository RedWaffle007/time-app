import 'dart:convert';

/// The reminder layer's value types. No plugins, no Firestore, no BuildContext —
/// everything here is pure, so the reconciler that consumes it is unit-testable
/// without a device.

/// What the app WANTS scheduled for one item: the output of reading a
/// [ScheduleItem], and the input to the reconciler.
///
/// Deliberately not a `ScheduleItem`. The reconciler must not be able to reach
/// item status, outcomes or archive state — the decision "should this item have
/// a reminder at all" is made once, in [desiredReminders], and everything
/// downstream sees only a title, a body and an instant.
class ReminderRequest {
  const ReminderRequest({
    required this.itemId,
    required this.fireAtUtc,
    required this.title,
    required this.body,
  });

  final String itemId;

  /// The absolute instant. Always UTC; the tz-aware conversion for the OS
  /// happens in the scheduler, at the edge.
  final DateTime fireAtUtc;

  final String title;
  final String body;

  /// Everything about this reminder that, if it changed, means the OS is now
  /// holding the wrong thing. Compared against the mirror to decide whether a
  /// re-schedule is needed — see [ScheduledReminder.fingerprint].
  String get fingerprint =>
      '${fireAtUtc.millisecondsSinceEpoch}|$title|$body';

  @override
  String toString() => 'ReminderRequest($itemId at $fireAtUtc)';
}

/// What the app BELIEVES is currently scheduled with the OS, as persisted in the
/// local mirror.
///
/// The mirror exists because **Android cannot be reliably queried for this.**
/// `pendingNotificationRequests()` reads flutter_local_notifications' own store,
/// which is a different store from ours and says nothing about whether the
/// underlying AlarmManager registration survived a reboot, an app update, or an
/// exact-alarm permission revocation. Trusting it would make "is this already
/// scheduled?" a question with a confident wrong answer.
class ScheduledReminder {
  const ScheduledReminder({
    required this.itemId,
    required this.notificationId,
    required this.fireAtUtc,
    required this.fingerprint,
  });

  final String itemId;

  /// The id actually used with the OS. Usually [reminderNotificationId] of
  /// [itemId], but not necessarily — see the collision note there. This field is
  /// the authority, never the hash.
  final int notificationId;

  final DateTime fireAtUtc;

  /// The [ReminderRequest.fingerprint] this was scheduled from.
  final String fingerprint;

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'notificationId': notificationId,
        'fireAtMs': fireAtUtc.millisecondsSinceEpoch,
        'fingerprint': fingerprint,
      };

  /// Returns null rather than throwing on a malformed row. A single corrupt
  /// entry must not make the whole mirror unreadable: an unreadable mirror is
  /// read as "nothing is scheduled", which re-schedules everything — recoverable
  /// — whereas a throw at startup would take the app down.
  static ScheduledReminder? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final itemId = raw['itemId'];
    final notificationId = raw['notificationId'];
    final fireAtMs = raw['fireAtMs'];
    final fingerprint = raw['fingerprint'];
    if (itemId is! String ||
        notificationId is! int ||
        fireAtMs is! int ||
        fingerprint is! String) {
      return null;
    }
    return ScheduledReminder(
      itemId: itemId,
      notificationId: notificationId,
      fireAtUtc: DateTime.fromMillisecondsSinceEpoch(fireAtMs, isUtc: true),
      fingerprint: fingerprint,
    );
  }

  static String encode(Iterable<ScheduledReminder> reminders) =>
      jsonEncode([for (final r in reminders) r.toJson()]);

  static List<ScheduledReminder> decode(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final raw = jsonDecode(json);
      if (raw is! List) return const [];
      return [
        for (final entry in raw) ?fromJson(entry),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  String toString() =>
      'ScheduledReminder($itemId #$notificationId at $fireAtUtc)';
}

// ---------------------------------------------------------------------------
// Notification ids: a Firestore string id → a 32-bit int the OS will accept.
// ---------------------------------------------------------------------------

/// The **preferred** notification id for an item, derived deterministically from
/// its Firestore document id.
///
/// Determinism is the requirement, not uniqueness. Android identifies a
/// scheduled notification by an `int` and nothing else, so cancelling one means
/// reproducing its id exactly — from a cold start, after a reboot, possibly with
/// a mirror that was wiped. A hash of the item id can always be recomputed; a
/// counter cannot.
///
/// FNV-1a, 32-bit, masked to 31 bits so the result is always positive. (Java's
/// `int` is signed and the plugin round-trips through it; a negative id is legal
/// but makes every log line harder to read for no gain.)
///
/// **The collision story.** 31 bits over Firestore's 20-character ids gives a
/// birthday collision around 2^15.5 ≈ 46,000 simultaneously-live reminders; at a
/// realistic 100 it is roughly one in twenty million. That is small, not zero,
/// and the failure it would cause is silent and bad — scheduling item B would
/// overwrite item A's alarm, so A simply never fires and nothing anywhere
/// reports a problem.
///
/// So the hash is only a *preference*. [allocateNotificationId] resolves a
/// collision by linear probing, and the winning id is recorded in the mirror,
/// which is the authority from then on. The overwhelmingly common case is
/// unchanged: no collision, id == hash, recomputable from the item id alone.
int reminderNotificationId(String itemId) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(itemId)) {
    hash ^= unit;
    // Dart ints are 64-bit; the mask is what keeps this genuinely 32-bit FNV-1a
    // rather than a different hash that happens to start the same way.
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}

/// Picks the id to schedule [itemId] under, avoiding [taken] — the ids already
/// in use by *other* items.
///
/// Probing is linear and wraps inside the 31-bit space, so the choice is a pure
/// function of (itemId, taken) and two devices with the same mirror reach the
/// same answer. The bound exists so a pathological mirror cannot spin forever;
/// exhausting it returns the base id, which at worst reinstates the collision
/// this is avoiding — and to exhaust it you would need 1,024 consecutive
/// occupied ids, which cannot happen by accident.
int allocateNotificationId(String itemId, Set<int> taken) {
  final base = reminderNotificationId(itemId);
  if (!taken.contains(base)) return base;
  for (var probe = 1; probe <= 1024; probe++) {
    final candidate = (base + probe) & 0x7FFFFFFF;
    if (!taken.contains(candidate)) return candidate;
  }
  return base;
}
