// Plan-request reminders (Batch G item 5, 2026-09-27; DECISIONS.md "Request
// Plan redesign"). X asked friend Y to plan a reminder for time T. Y was
// pushed at once; if Y has still not CREATED the plan, Y is reminded at 50%
// and at 75% of the window W = T − (when the request was sent). 4 PM → 6 PM:
// 5:00 and 5:30 (to within this 2-minute cron).
//
// Only creating the plan stops them (the request becomes `fulfilled`) —
// merely opening it does not. A declined, cancelled or past-due request never
// reminds. Each reminder is claimed with a conditional write against the
// request's updateTime, so two cron runs cannot both send it.

import { ACTIVITY_CHANNEL_ID } from './notify.js';

export const REMINDER_FRACTIONS = [0.5, 0.75];

/** The reminder instants for a request sent at [sentAt] for [due]. */
export function reminderTimes(sentAt, due) {
  const window = due.getTime() - sentAt.getTime();
  if (!(window > 0)) return [];
  return REMINDER_FRACTIONS.map((f) => new Date(sentAt.getTime() + window * f));
}

/** How many reminder slots have come due by [now]. */
export function slotsDue(sentAt, due, now) {
  return reminderTimes(sentAt, due).filter((t) => t.getTime() <= now.getTime()).length;
}

export function planRequestBody(requesterName) {
  return `${requesterName} has requested you to plan for them. Click to view details.`;
}

function isOpen(status) {
  return status === 'pending' || status === 'inProgress';
}

/** `ctx = { db, fcm }`. Returns a summary for the cron log. */
export async function sendPlanRequestReminders(ctx, now) {
  const rows = await ctx.db.listUpcomingPlanRequests(now, 200);
  let reminded = 0;
  for (const { id, data, updateTime } of rows) {
    if (!isOpen(data.status) || !data.createdAt || !data.windowStartUtc) continue;
    const sentAt = new Date(data.createdAt);
    const due = new Date(data.windowStartUtc);
    if (now.getTime() >= due.getTime()) continue;
    const already = Number.isInteger(data.remindersSent) ? data.remindersSent : 0;
    const dueSlots = slotsDue(sentAt, due, now);
    if (dueSlots <= already) continue;

    // Claim first: a missed slot is skipped, never sent late as a second push.
    const claimed = await ctx.db.patchDocIfUnchanged(`planRequests/${id}`, {
      remindersSent: dueSlots,
      lastReminderAt: now,
    }, updateTime);
    if (!claimed) continue;

    const requester = await ctx.db.getDoc(`users/${data.requesterUid}`);
    const who = requester && requester.name ? String(requester.name) : 'A friend';
    const tokens = await ctx.db.listDocIds(`users/${data.plannerUid}/fcmTokens`);
    for (const token of tokens) {
      const res = await ctx.fcm.send(token, {
        notification: { title: 'Reminder', body: planRequestBody(who) },
        android: { priority: 'high', notification: { channel_id: ACTIVITY_CHANNEL_ID } },
        data: {
          type: 'planRequested',
          event: 'planRequested',
          fromUid: String(data.requesterUid),
          toUid: String(data.plannerUid),
          planRequestId: id,
          reminder: 'true',
        },
      });
      if (res.ok) reminded += 1;
      else if (res.error === 'UNREGISTERED' || res.error === 'INVALID') {
        await ctx.db.deleteDoc(`users/${data.plannerUid}/fcmTokens/${token}`);
      }
    }
  }
  return { scanned: rows.length, reminded };
}
