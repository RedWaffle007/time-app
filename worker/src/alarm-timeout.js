// alarm-timeout.js — the target's phone reports, the moment its alarm rang
// out unanswered, that the person was unavailable (2026-09-27).
//
// Why the Worker records it: the one-minute auto-stop runs in native code,
// usually with the app's Dart side not running, so the old path (Dart writes
// `alarm.unavailableAt`, then asks for the `unavailable` push) only ran when
// the person next opened the app, often when they answered Done/Skip. The
// native side now POSTs here with the user's ID token; the Worker writes the
// fact with its service account and sends the existing `unavailable` push,
// whose own dedup slot makes the later Dart report a no-op.

export const ALARM_TIMEOUT_EVENT = 'alarmTimeout';

// The alarm rings at its time and gives up after up to a minute, so a report
// earlier than this after the scheduled instant is not a real timeout.
export const MIN_AFTER_SCHEDULED_MS = 30 * 1000;
// A report days late is not "the moment the alarm stopped"; the Dart path and
// the end-of-day lapse own anything that old.
export const MAX_AFTER_SCHEDULED_MS = 24 * 60 * 60 * 1000;

/**
 * Whether [item] may take `alarm.unavailableAt` now, and at what instant.
 * Pure: no I/O, no clock.
 *
 * - ok:false with a reason: nothing is written and nothing is sent.
 * - ok:true, write:false: the fact is already there (the Dart path or an
 *   earlier report won); the push may still be owed.
 * - ok:true, write:true, at: write this instant, then push.
 */
export function alarmTimeoutDecision(item, nowMs, reportedAtMs) {
  if (!item) return { ok: false, reason: 'item-not-found' };
  // Only a live alarm rings; a cancelled or withdrawn plan has none.
  if (item.status !== 'approved') return { ok: false, reason: 'not-live' };
  // A dismissed alarm did not ring out.
  if (item.alarm && item.alarm.dismissedAt) {
    return { ok: false, reason: 'dismissed' };
  }
  const scheduledMs = Date.parse(item.scheduledInstantUtc);
  if (!Number.isFinite(scheduledMs)) {
    return { ok: false, reason: 'item-missing-fields' };
  }
  if (nowMs < scheduledMs + MIN_AFTER_SCHEDULED_MS) {
    return { ok: false, reason: 'too-early' };
  }
  if (nowMs > scheduledMs + MAX_AFTER_SCHEDULED_MS) {
    return { ok: false, reason: 'too-late' };
  }
  if (item.alarm && item.alarm.unavailableAt) {
    return { ok: true, write: false };
  }
  // The phone's own instant, kept within [scheduled, now] so a wrong clock
  // can neither predate the alarm nor claim the future.
  const reported = Number.isFinite(reportedAtMs) ? reportedAtMs : nowMs;
  const atMs = Math.min(Math.max(reported, scheduledMs), nowMs);
  return { ok: true, write: true, at: new Date(atMs) };
}

/**
 * Records `alarm.unavailableAt` once (compare-and-set on the item's
 * updateTime, only that nested field). Returns { ready, recorded, reason }:
 * `ready` means the fact is now stored and the push may be sent.
 */
export async function recordAlarmTimeout(db, { targetUid, itemId, nowMs, reportedAtMs }) {
  const path = `scheduleItems/${targetUid}/items/${itemId}`;
  for (let attempt = 0; attempt < 3; attempt++) {
    const meta = await db.getDocWithMeta(path);
    const decision = alarmTimeoutDecision(meta && meta.data, nowMs, reportedAtMs);
    if (!decision.ok) return { ready: false, recorded: false, reason: decision.reason };
    if (!decision.write) return { ready: true, recorded: false, reason: 'already-recorded' };
    const won = await db.patchDocIfUnchanged(
      path,
      { alarm: { unavailableAt: decision.at } },
      meta.updateTime,
      ['alarm.unavailableAt'],
    );
    if (won) return { ready: true, recorded: true, reason: 'recorded' };
    // Something else touched the item (a ring stamp, the Dart report):
    // re-read and decide again.
  }
  return { ready: false, recorded: false, reason: 'conflict' };
}
