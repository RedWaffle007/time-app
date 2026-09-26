// Approval reminders: while a plan someone made for you is still PENDING, remind
// you before it is due. Transport-independent like notify.js / inactivity.js.
//
// Why server-side (DECISIONS.md "Approval reminders", 2026-09-26): the Worker
// reads the plan's LIVE status in the same conditional write that claims a
// reminder, so an approve/reject/withdraw made anywhere stops every later
// reminder — nothing on the target's phone has to be cancelled.

import { ACTIVITY_CHANNEL_ID, itemGrantPath } from './notify.js';

const MINUTE_MS = 60 * 1000;
export const MAX_APPROVAL_REMINDERS = 3;
export const MIN_REMINDER_GAP_MS = 2 * MINUTE_MS;
const SHORT_WINDOW_MS = 10 * MINUTE_MS;
const LONG_WINDOW_MS = 2 * 60 * MINUTE_MS;

// Each reminder costs ~6 Firestore/FCM subrequests, ~9 when it is the final
// one (the planner heads-up adds a name read, a token list and a send);
// Cloudflare's free plan allows 50 per invocation. Anything beyond this waits
// for the next minute.
export const MAX_REMINDERS_PER_RUN = 5;
export const PENDING_SCAN_LIMIT = 50;

/**
 * When to remind, as epoch-ms instants, scaled to the window
 * W = due − created (the approved strategy, handoff.md item 13):
 *   W < 10 min      → one, at W/2
 *   10 min ≤ W < 2h → W/2, and a final one at due − clamp(W/10, 3, 10 min)
 *   W ≥ 2h          → W/2, due − 1h, and a final one at due − 10 min
 * Never more than three; the final one is always kept; any other reminder
 * less than MIN_REMINDER_GAP_MS before the next kept one is dropped.
 */
export function approvalReminderTimes(createdAtMs, dueAtMs) {
  if (!Number.isFinite(createdAtMs) || !Number.isFinite(dueAtMs)) return [];
  const w = dueAtMs - createdAtMs;
  if (w <= 0) return [];

  const half = createdAtMs + w / 2;
  let candidates;
  if (w < SHORT_WINDOW_MS) {
    candidates = [half];
  } else if (w < LONG_WINDOW_MS) {
    const lead = Math.min(10 * MINUTE_MS, Math.max(3 * MINUTE_MS, w / 10));
    candidates = [half, dueAtMs - lead];
  } else {
    candidates = [half, dueAtMs - 60 * MINUTE_MS, dueAtMs - 10 * MINUTE_MS];
  }

  const sorted = candidates
    .map(Math.round)
    .filter((t) => t > createdAtMs && t < dueAtMs)
    .sort((a, b) => a - b);
  const kept = [];
  for (let i = sorted.length - 1; i >= 0; i--) {
    const next = kept[0];
    if (next === undefined || next - sorted[i] >= MIN_REMINDER_GAP_MS) {
      kept.unshift(sorted[i]);
    }
  }
  return kept.slice(-MAX_APPROVAL_REMINDERS);
}

/**
 * Which reminder (index into [times]) is due now, given how many were already
 * sent. Only the LATEST past slot is returned: if the Worker was down across
 * several slots the target gets one reminder, not a burst.
 */
export function dueReminderIndex(times, alreadySent, nowMs) {
  let due = -1;
  for (let i = Math.max(0, alreadySent); i < times.length; i++) {
    if (times[i] <= nowMs) due = i;
  }
  return due;
}

export function buildApprovalReminderMessage({
  title, plannerName, groupName, isFinal, targetUid, itemId,
}) {
  const task = (title || 'your scheduled item').toString();
  const who = plannerName || 'Someone';
  const isGroup = typeof groupName === 'string';
  const body = isGroup
    ? `Group task: ${task} planned by ${who}${groupName ? ` in ${groupName}` : ''} is waiting for your approval.`
    : `Task: ${task} planned by ${who} is waiting for your approval.`;
  return {
    notification: {
      title: isFinal ? 'Due soon: waiting for your approval' : 'Waiting for your approval',
      body,
    },
    data: {
      type: 'approvalReminder',
      event: 'approvalReminder',
      targetUid,
      itemId,
    },
    android: {
      priority: 'high',
      notification: { channel_id: ACTIVITY_CHANNEL_ID },
    },
  };
}

/**
 * The planner's one heads-up (item 16, 2026-09-26), sent with the FINAL
 * reminder while the plan is still pending. No clock time (decided: push text
 * cannot follow the recipient's locale).
 */
export function buildPlannerPendingMessage({
  title, targetName, groupName, targetUid, itemId,
}) {
  const task = (title || 'your scheduled item').toString();
  const who = targetName || 'Someone';
  const where = groupName ? ` in ${groupName}` : '';
  return {
    notification: {
      title: typeof groupName === 'string'
        ? 'Group plan still waiting for approval'
        : 'Still waiting for approval',
      body: `${who} hasn't approved ${task}${where} yet. It's due soon.`,
    },
    data: {
      type: 'approvalPending',
      event: 'approvalPending',
      targetUid,
      itemId,
    },
    android: {
      priority: 'high',
      notification: { channel_id: ACTIVITY_CHANNEL_ID },
    },
  };
}

/**
 * One cron pass. `ctx.db.listPendingItems(now, limit)` returns pending items
 * due after `now`: `{ path, data, updateTime, createTime }`.
 */
export async function sendDueApprovalReminders(ctx, now = new Date(), {
  maxReminders = MAX_REMINDERS_PER_RUN,
  scanLimit = PENDING_SCAN_LIMIT,
} = {}) {
  const nowMs = now.getTime();
  const rows = await ctx.db.listPendingItems(now, scanLimit);
  const summary = {
    considered: rows.length, claimed: 0, sent: 0, cleaned: 0, plannerHeadsUps: 0,
  };

  for (const row of rows) {
    if (summary.claimed >= maxReminders) break;
    const match = /^scheduleItems\/([^/]+)\/items\/([^/]+)$/.exec(row.path || '');
    if (!match || !row.updateTime) continue;
    const [, targetUid, itemId] = match;
    const item = row.data || {};
    const plannerUid = item.createdByUid;
    if (item.status !== 'pending' || item.targetUid !== targetUid) continue;
    if (!plannerUid || plannerUid === targetUid) continue; // self-plans never remind

    const dueMs = Date.parse(item.scheduledInstantUtc);
    const createdMs = Date.parse(item.createdAt || row.createTime);
    if (!(dueMs > nowMs)) continue;
    const times = approvalReminderTimes(createdMs, dueMs);
    const sent = Number.isInteger(item.approvalRemindersSent)
      ? item.approvalRemindersSent
      : 0;
    const index = dueReminderIndex(times, sent, nowMs);
    if (index < 0) continue;

    // A revoked grant means no push, exactly like the item events.
    const grant = await ctx.db.getDoc(itemGrantPath(item, plannerUid, targetUid));
    if (!grant || grant.granted !== true) continue;

    // Claim THIS slot only if the item is unchanged since the query. An
    // approve/reject/withdraw (or a concurrent run) changes updateTime, so the
    // claim fails and nothing is sent.
    const path = `scheduleItems/${targetUid}/items/${itemId}`;
    const claimed = await ctx.db.patchDocIfUnchanged(path, {
      approvalRemindersSent: index + 1,
      approvalRemindedAt: now,
    }, row.updateTime);
    if (!claimed) continue;
    summary.claimed += 1;

    const planner = await ctx.db.getDoc(`users/${plannerUid}`);
    const group = item.groupId ? await ctx.db.getDoc(`groups/${item.groupId}`) : null;
    const groupName = item.groupId
      ? (group && group.name ? String(group.name) : '')
      : null;
    const isFinal = index === times.length - 1;
    const message = buildApprovalReminderMessage({
      title: item.title,
      plannerName: planner && planner.name ? String(planner.name) : null,
      groupName,
      isFinal,
      targetUid,
      itemId,
    });
    await sendToUser(ctx, targetUid, message, summary);

    // Riding the same claimed slot, so it can never repeat: the final
    // reminder's slot is claimed exactly once.
    if (isFinal) {
      const target = await ctx.db.getDoc(`users/${targetUid}`);
      await sendToUser(ctx, plannerUid, buildPlannerPendingMessage({
        title: item.title,
        targetName: target && target.name ? String(target.name) : null,
        groupName,
        targetUid,
        itemId,
      }), summary);
      summary.plannerHeadsUps += 1;
    }
  }

  return summary;
}

async function sendToUser(ctx, uid, message, summary) {
  const tokens = await ctx.db.listDocIds(`users/${uid}/fcmTokens`);
  for (const token of tokens) {
    const result = await ctx.fcm.send(token, message);
    if (result.ok) {
      summary.sent += 1;
    } else if (result.error === 'UNREGISTERED' || result.error === 'INVALID') {
      await ctx.db.deleteDoc(`users/${uid}/fcmTokens/${token}`);
      summary.cleaned += 1;
    }
  }
}
