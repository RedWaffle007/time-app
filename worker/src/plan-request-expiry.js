// Plan-request expiry (2026-09-28; DECISIONS.md "Plan requests expire").
// X asked friend Y to plan a reminder for minute T. Once T passes with no plan
// set, the request closes as `expired` and BOTH people are told, each with the
// time in their own zone.
//
// Runs in the 2-minute cron beside the reminders. The expiry is claimed with a
// conditional write against the request's updateTime, so a plan created at the
// last second (which rewrites the request) wins, and two cron runs cannot both
// expire — or both notify — the same request.
//
// A request that passed long ago (older than the notify window, e.g. the
// backlog on the first deploy) is expired silently: a push about something
// hours old is noise. Older than the lookback it is never touched; the app
// treats any open request whose time has passed as finished anyway.

import { ACTIVITY_CHANNEL_ID, UNAVAILABLE_CHANNEL_ID } from './notify.js';
import { formatTimeIn } from './group-plan.js';

export const EXPIRY_LOOKBACK_MS = 24 * 60 * 60 * 1000;
export const EXPIRY_NOTIFY_MS = 30 * 60 * 1000;

function isOpen(status) {
  return status === 'pending' || status === 'inProgress';
}

/** The last minute a plan could still start (the app's `lastStartUtc`). */
export function lastStart(data) {
  const minutes = Number(data.durationMinutes);
  if (data.windowEndUtc && Number.isFinite(minutes) && minutes > 0) {
    return new Date(new Date(data.windowEndUtc).getTime() - minutes * 60 * 1000);
  }
  return new Date(data.windowStartUtc);
}

function cleanTask(title) {
  return String(title || '').replace(/\s+/g, ' ').trim() || 'a task';
}

/** The two notices. [time*] are already formatted in each person's zone. */
export function expiryMessages({ requesterName, plannerName, task, timeForRequester, timeForPlanner }) {
  return {
    requester: {
      title: 'Plan request not set',
      body: `${plannerName} didn't set your alarm for "${task}" at ${timeForRequester}. The requested time has passed.`,
    },
    planner: {
      title: 'Plan request missed',
      body: `You didn't set ${requesterName}'s alarm for "${task}" at ${timeForPlanner}. The requested time has passed.`,
    },
  };
}

// The requester's notice is a negative event and plays the "Uh-Oh!"
// (2026-09-28); the friend who did not plan it hears the normal tone.
async function push(ctx, uid, message, data, { uhOh = false } = {}) {
  const tokens = await ctx.db.listDocIds(`users/${uid}/fcmTokens`);
  let sent = 0;
  for (const token of tokens) {
    const res = await ctx.fcm.send(token, {
      notification: message,
      android: {
        priority: 'high',
        notification: { channel_id: uhOh ? UNAVAILABLE_CHANNEL_ID : ACTIVITY_CHANNEL_ID },
      },
      data: uhOh ? { ...data, uhOh: 'true' } : data,
    });
    if (res.ok) sent += 1;
    else if (res.error === 'UNREGISTERED' || res.error === 'INVALID') {
      await ctx.db.deleteDoc(`users/${uid}/fcmTokens/${token}`);
    }
  }
  return sent;
}

/** `ctx = { db, fcm }`. Returns a summary for the cron log. */
export async function expirePlanRequests(ctx, now) {
  const since = new Date(now.getTime() - EXPIRY_LOOKBACK_MS);
  const rows = await ctx.db.listDuePlanRequests(since, now, 200);
  let expired = 0;
  let sent = 0;
  for (const { id, data, updateTime } of rows) {
    if (!isOpen(data.status) || !data.windowStartUtc) continue;
    const due = lastStart(data);
    if (now.getTime() < due.getTime()) continue;

    const claimed = await ctx.db.patchDocIfUnchanged(`planRequests/${id}`, {
      status: 'expired',
      expiredAt: now,
      updatedAt: now,
    }, updateTime);
    if (!claimed) continue;
    expired += 1;
    if (now.getTime() - due.getTime() > EXPIRY_NOTIFY_MS) continue;

    const [requester, planner] = await Promise.all([
      ctx.db.getDoc(`users/${data.requesterUid}`),
      ctx.db.getDoc(`users/${data.plannerUid}`),
    ]);
    const zoneOf = (user, fallback) =>
      user && user.homeTimezone ? String(user.homeTimezone) : fallback;
    const messages = expiryMessages({
      requesterName: requester && requester.name ? String(requester.name) : 'your friend',
      plannerName: planner && planner.name ? String(planner.name) : 'Your friend',
      task: cleanTask(data.title),
      timeForRequester: formatTimeIn(due, zoneOf(requester, data.timezone || 'UTC')),
      timeForPlanner: formatTimeIn(due, zoneOf(planner, 'UTC')),
    });
    const base = {
      type: 'planRequestExpired',
      event: 'planRequestExpired',
      fromUid: String(data.requesterUid),
      toUid: String(data.plannerUid),
      planRequestId: id,
    };
    sent += await push(ctx, data.requesterUid, messages.requester,
      { ...base, audience: 'requester' }, { uhOh: true });
    sent += await push(ctx, data.plannerUid, messages.planner, { ...base, audience: 'planner' });
  }
  return { scanned: rows.length, expired, sent };
}
