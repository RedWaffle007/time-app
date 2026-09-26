import 'package:cloud_firestore/cloud_firestore.dart';

/// Strips clock/meridian residue that speech-to-text sometimes leaves in a
/// title ("a.m. cycling", "cycling p.m.").
///
/// Applied on every READ (`ScheduleItem.fromDoc`) and every WRITE
/// (`ScheduleRepository.createItem`), so legacy items written before the voice
/// parser learned to drop meridians render clean with no migration, and new
/// items — voice OR manual — are stored clean.
///
/// Conservative on purpose, so it never eats a real word:
///  - a DOTTED meridian ("a.m.", "p.m.", "a.m") is residue wherever it sits and
///    is dropped anywhere — no English word looks like that;
///  - a BARE "am"/"pm" is dropped ONLY at the very start or end of the title,
///    never interior, so "I am tired" and "spam folder" keep their letters.
///
/// If stripping would empty the title (e.g. the title was literally "a.m."), the
/// trimmed original is kept — a blank title helps no one.
String sanitizeScheduleTitle(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final dotted = RegExp(r'^[ap]\.m\.?[.,;:!?]*$', caseSensitive: false);
  final bare = RegExp(r'^[ap]m[.,;:!?]*$', caseSensitive: false);
  final tokens = trimmed.split(RegExp(r'\s+'))
    ..removeWhere((t) => dotted.hasMatch(t));
  while (tokens.isNotEmpty && bare.hasMatch(tokens.first)) {
    tokens.removeAt(0);
  }
  while (tokens.isNotEmpty && bare.hasMatch(tokens.last)) {
    tokens.removeLast();
  }
  final result = tokens.join(' ').trim();
  return result.isEmpty ? trimmed : result;
}

/// Lifecycle status of a schedule item (see data-model.md state machine).
enum ScheduleItemStatus { pending, approved, rejected, cancelled, withdrawn }

/// The item tier (#5). [normal] items require the target's per-item approval
/// before they fire (the default, and every pre-#5 item). [emergency] items are
/// created already-`approved` by a planner holding the SEPARATE emergency grant,
/// so they skip the queue and fire directly. See DECISIONS.md "Emergency item
/// tier". `tier` defaults to [normal] everywhere it is absent.
enum ItemTier { normal, emergency }

enum OutcomeResult { done, skipped }

/// The automatic outcome reason written when an alarm rings for its full
/// one-minute cap without a response. Kept in the domain layer so persistence,
/// rules-facing repositories, and presentation agree on the exact value.
const kUserUnavailableSkipReason = 'User unavailable';

/// The outcome layered on top of an approved item. Kept separate from status so
/// approval and completion stay two distinct facts (the accountability signal).
class ScheduleOutcome {
  const ScheduleOutcome({
    required this.result,
    this.completedAt,
    this.skippedAt,
    this.skipReason,
  });

  final OutcomeResult result;
  final DateTime? completedAt;
  final DateTime? skippedAt;
  final String? skipReason;

  static ScheduleOutcome? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final result = m['result'] == 'skipped'
        ? OutcomeResult.skipped
        : OutcomeResult.done;
    return ScheduleOutcome(
      result: result,
      completedAt: (m['completedAt'] as Timestamp?)?.toDate(),
      skippedAt: (m['skippedAt'] as Timestamp?)?.toDate(),
      skipReason: m['skipReason'] as String?,
    );
  }
}

/// Device-observed alarm lifecycle, synchronized into the shared item so the
/// planner can see what actually happened without access to the target's phone.
class ScheduleAlarmTimeline {
  const ScheduleAlarmTimeline({
    this.rangAt,
    this.dismissedAt,
    this.unavailableAt,
  });

  final DateTime? rangAt;
  final DateTime? dismissedAt;

  /// The alarm exhausted its one-minute cap without a response. Unlike the
  /// mutable task outcome, this device-observed fact is permanent.
  final DateTime? unavailableAt;

  static ScheduleAlarmTimeline? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final rangAt = (map['rangAt'] as Timestamp?)?.toDate();
    final dismissedAt = (map['dismissedAt'] as Timestamp?)?.toDate();
    final unavailableAt = (map['unavailableAt'] as Timestamp?)?.toDate();
    if (rangAt == null && dismissedAt == null && unavailableAt == null) {
      return null;
    }
    return ScheduleAlarmTimeline(
      rangAt: rangAt,
      dismissedAt: dismissedAt,
      unavailableAt: unavailableAt,
    );
  }
}

/// The planner's voice note on someone else's alarm (item 32). Only metadata:
/// the audio lives in the Worker's private bucket and is fetched by the
/// target's device, which checks it against [sha256].
class VoiceNoteMeta {
  const VoiceNoteMeta({
    required this.durationMs,
    required this.sha256,
    required this.sizeBytes,
    this.deliveredAt,
  });

  final int durationMs;
  final String sha256;
  final int sizeBytes;

  /// The target's device holds a verified copy (the delivery receipt, 32c).
  final DateTime? deliveredAt;

  Map<String, dynamic> toCreateMap() => {
    'durationMs': durationMs,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
  };

  static VoiceNoteMeta? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final duration = raw['durationMs'];
    final sha = raw['sha256'];
    final size = raw['sizeBytes'];
    if (duration is! num || sha is! String || size is! num) return null;
    return VoiceNoteMeta(
      durationMs: duration.toInt(),
      sha256: sha,
      sizeBytes: size.toInt(),
      deliveredAt: (raw['deliveredAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// A timetable item a planner created for a target. Stored at
/// `scheduleItems/{targetUid}/items/{itemId}`.
class ScheduleItem {
  const ScheduleItem({
    required this.id,
    required this.targetUid,
    required this.createdByUid,
    required this.groupId,
    required this.title,
    required this.localWallTime,
    required this.timezone,
    required this.scheduledInstantUtc,
    required this.status,
    this.tier = ItemTier.normal,
    this.durationMinutes = 0,
    this.planRequestId,
    this.voiceNote,
    this.note,
    this.outcome,
    this.alarm,
    this.rejectionReason,
    this.createdAt,
    this.decidedAt,
  });

  final String id;
  final String targetUid;
  final String createdByUid;
  final String groupId;
  final String title;
  final String? note;

  /// Wall-clock the planner set, e.g. "2026-07-20T09:00" (no offset).
  final String localWallTime;

  /// IANA zone the item was built against (snapshot of target's home tz).
  final String timezone;

  /// Absolute instant = localWallTime resolved in timezone. Source of truth.
  final DateTime scheduledInstantUtc;

  final ScheduleItemStatus status;

  /// Normal (queued) or emergency (auto-approved). See [ItemTier].
  final ItemTier tier;

  /// Optional occupied duration introduced with plan requests. Existing items
  /// have no field and remain point alarms (`0`), so this is migration-free.
  final int durationMinutes;

  /// Soft provenance link for an item created while fulfilling Item 23. The
  /// request is never authority; rules still require the live normal grant.
  final String? planRequestId;

  /// Voice-note alarm (item 32); null for a ringtone alarm.
  final VoiceNoteMeta? voiceNote;

  final ScheduleOutcome? outcome;
  final ScheduleAlarmTimeline? alarm;
  final String? rejectionReason;
  final DateTime? createdAt;

  /// When the target decided (approved/rejected), or when a self-authored item
  /// was created already-approved. Written by `approve`/`reject`/self-create and
  /// permitted by the item rules' decision whitelist. The source for future
  /// response-latency stats (`decidedAt - createdAt`), which is why it is
  /// captured now: it cannot be reconstructed for a plan decided before the
  /// field existed. Null on a still-pending item and on planner-withdrawn items
  /// (a withdrawal is not a target decision; it carries `withdrawnAt` instead).
  final DateTime? decidedAt;

  // -------------------------------------------------------------------------
  // Archive eligibility (DECISIONS.md "Archive — the terminal-state split").
  //
  // Terminal is NOT one bucket. Two terminal states are clutter the instant
  // they occur, and two are not:
  //
  //   rejected / withdrawn  → AUTO-hidden on entry. Rejecting IS the clearing
  //                           action; a rejected row must never sit in the
  //                           Activity feed piling up.
  //   done / skipped        → MANUAL. These are not clutter the moment they
  //                           happen — you archive them when you're ready.
  //
  // Both are hide-only. The document is untouched in every case, so summaries,
  // stats and any future records generation still count the item — provided
  // they read the RECORD providers, not the filtered views. That constraint is
  // stated where it can be violated, in `schedule_providers.dart`.
  //
  // A LIVE item (`pending`, or `approved`-not-done) is never hideable by either
  // route. Hiding one would let you bury a plan you never responded to, which
  // is the accountability failure the whole design exists to prevent.
  // -------------------------------------------------------------------------

  /// Hidden from both parties' feeds automatically, the moment the status is
  /// set. **Not a stored flag — a pure view rule**, and necessarily so: the
  /// person who rejects is not the person whose feed is cluttered (a rejected
  /// item never appears in the target's own views at all; the pile-up is in the
  /// PLANNER's Activity feed). Clearing it by writing an archive entry would
  /// require the target to write into the planner's own subtree, destroying the
  /// property that makes this shape safe — nobody can affect anyone else's data.
  /// As a view rule it costs no write, cannot half-fail, and needs no rule.
  ///
  /// `cancelled` rides along as a dead state. No code path sets it today.
  bool get isAutoArchived =>
      status == ScheduleItemStatus.rejected ||
      status == ScheduleItemStatus.withdrawn ||
      status == ScheduleItemStatus.cancelled;

  /// Settled with a recorded outcome, so the user may archive it by hand. This
  /// is the only route that writes to `users/{uid}/state/archived`, and the only
  /// one that is reversible from the Archived screen — un-hiding a rejected row
  /// would just put the clutter back.
  bool get isManuallyArchivable => outcome != null;

  /// Nothing further will happen to this item.
  bool get isSettled => isAutoArchived || isManuallyArchivable;

  /// How late completion was, relative to the scheduled instant. Null unless the
  /// item was marked **done** and completion landed AFTER the scheduled time (an
  /// on-time or early completion has no delay to show).
  ///
  /// **Derived, never stored.** The delay is `completedAt - scheduledInstantUtc`
  /// and both are already persisted — a stored `delayMinutes` would only be a
  /// second copy to drift. A done item with no `completedAt` (legacy data) has
  /// no measurable delay and returns null rather than a guessed one.
  Duration? get completionDelay {
    final o = outcome;
    if (o == null || o.result != OutcomeResult.done) return null;
    final done = o.completedAt;
    if (done == null) return null;
    final d = done.difference(scheduledInstantUtc);
    return d > Duration.zero ? d : null;
  }

  /// Completed, but after its scheduled time — honest data surfaced in the UI
  /// and in stats, never dropped. See [completionDelay].
  bool get wasCompletedLate => completionDelay != null;

  /// Delivery/response-time fact, independent of the current completion
  /// outcome. The skip-reason fallback keeps legacy timeout rows legible until
  /// their separate alarm event is backfilled from the durable native queue.
  bool get wasUnavailableAtAlarmTime =>
      alarm?.unavailableAt != null ||
      outcome?.skipReason == kUserUnavailableSkipReason;

  factory ScheduleItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return ScheduleItem(
      id: doc.id,
      targetUid: (d['targetUid'] ?? '') as String,
      createdByUid: (d['createdByUid'] ?? '') as String,
      groupId: (d['groupId'] ?? '') as String,
      title: sanitizeScheduleTitle((d['title'] ?? '') as String),
      note: d['note'] as String?,
      localWallTime: (d['localWallTime'] ?? '') as String,
      timezone: (d['timezone'] ?? '') as String,
      scheduledInstantUtc:
          (d['scheduledInstantUtc'] as Timestamp?)?.toDate() ??
          DateTime.now().toUtc(),
      status: ScheduleItemStatus.values.firstWhere(
        (s) => s.name == d['status'],
        orElse: () => ScheduleItemStatus.pending,
      ),
      tier: d['tier'] == 'emergency' ? ItemTier.emergency : ItemTier.normal,
      durationMinutes: (d['durationMinutes'] as num?)?.toInt() ?? 0,
      planRequestId: d['planRequestId'] as String?,
      voiceNote: VoiceNoteMeta.fromMap(d['voiceNote']),
      outcome: ScheduleOutcome.fromMap(d['outcome'] as Map<String, dynamic>?),
      alarm: ScheduleAlarmTimeline.fromMap(d['alarm'] as Map<String, dynamic>?),
      rejectionReason: d['rejectionReason'] as String?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      decidedAt: (d['decidedAt'] as Timestamp?)?.toDate(),
    );
  }
}
