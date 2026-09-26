// Voice-note pre-alarm rescue (item 32c, 2026-09-26). The target's phone
// normally fetches the note as soon as the plan is approved (its reconciler
// stamps `voiceNote.deliveredAt`). If that has not happened as the alarm gets
// close:
//   ≤ 30 min before: a high-priority DATA push asks the phone to fetch it in
//                    the background (works on a killed app);
//   ≤ 10 min before: the planner is told it will ring with the normal
//                    ringtone unless the note arrives.
// Each step is claimed once with a conditional write, so it never repeats.

import { ACTIVITY_CHANNEL_ID, hasActiveItemGrant } from './notify.js';

const MIN = 60 * 1000;
export const RESCUE_PUSH_WINDOW_MS = 30 * MIN;
export const PLANNER_NOTICE_WINDOW_MS = 10 * MIN;
// ~4 subrequests per push, ~6 per notice; shares the lapse invocation's budget.
export const MAX_RESCUE_PUSHES_PER_RUN = 2;
export const MAX_PLANNER_NOTICES_PER_RUN = 1;

export function buildVoiceFetchCommand(targetUid, itemId) {
  return {
    // Data-only + high priority so the registered background handler runs.
    android: { priority: 'high' },
    data: {
      type: 'fetchVoiceNote',
      event: 'fetchVoiceNote',
      command: 'fetchVoiceNote',
      targetUid,
      itemId,
    },
  };
}

export function buildVoiceUndeliveredMessage({ title, targetName, targetUid, itemId }) {
  const task = (title || 'your scheduled item').toString();
  const who = targetName || 'Someone';
  return {
    notification: {
      title: 'Voice note not delivered yet',
      body: `Your voice note hasn't reached ${who}'s phone yet. If it doesn't arrive, ${task} will ring with the normal ringtone.`,
    },
    data: { type: 'voiceUndelivered', event: 'voiceUndelivered', targetUid, itemId },
    android: { priority: 'high', notification: { channel_id: ACTIVITY_CHANNEL_ID } },
  };
}

async function sendTo(ctx, uid, message, summary) {
  const tokens = await ctx.db.listDocIds(`users/${uid}/fcmTokens`);
  for (const token of tokens) {
    const result = await ctx.fcm.send(token, message);
    if (result.ok) summary.sent += 1;
    else if (result.error === 'UNREGISTERED' || result.error === 'INVALID') {
      await ctx.db.deleteDoc(`users/${uid}/fcmTokens/${token}`);
      summary.cleaned += 1;
    }
  }
}

export async function rescueUndeliveredVoiceNotes(ctx, now = new Date(), {
  maxPushes = MAX_RESCUE_PUSHES_PER_RUN,
  maxNotices = MAX_PLANNER_NOTICES_PER_RUN,
} = {}) {
  const nowMs = now.getTime();
  const summary = { pushes: 0, notices: 0, sent: 0, cleaned: 0 };
  const rows = await ctx.db.listItemsScheduledBetween(
    'approved',
    now.toISOString(),
    new Date(nowMs + RESCUE_PUSH_WINDOW_MS).toISOString(),
    50,
  );
  for (const row of rows) {
    if (summary.pushes >= maxPushes && summary.notices >= maxNotices) break;
    const match = /^scheduleItems\/([^/]+)\/items\/([^/]+)$/.exec(row.path || '');
    if (!match || !row.updateTime) continue;
    const [, targetUid, itemId] = match;
    const item = row.data || {};
    if (item.targetUid !== targetUid || item.status !== 'approved' || item.outcome) continue;
    const plannerUid = item.createdByUid;
    if (!plannerUid || plannerUid === targetUid) continue;
    const note = item.voiceNote;
    if (!note || note.deliveredAt) continue;
    const dueMs = Date.parse(item.scheduledInstantUtc);
    if (!(dueMs > nowMs)) continue;
    const path = `scheduleItems/${targetUid}/items/${itemId}`;

    if (!item.voiceRescuePushAt) {
      if (summary.pushes >= maxPushes) continue;
      const claimed = await ctx.db.patchDocIfUnchanged(path, { voiceRescuePushAt: now }, row.updateTime);
      if (!claimed) continue;
      summary.pushes += 1;
      await sendTo(ctx, targetUid, buildVoiceFetchCommand(targetUid, itemId), summary);
      continue;
    }

    if (dueMs - nowMs > PLANNER_NOTICE_WINDOW_MS || item.notifiedVoiceUndelivered) continue;
    if (summary.notices >= maxNotices) continue;
    if (!(await hasActiveItemGrant(ctx.db, item, plannerUid, targetUid))) continue;
    const claimed = await ctx.db.patchDocIfUnchanged(path, { notifiedVoiceUndelivered: true }, row.updateTime);
    if (!claimed) continue;
    summary.notices += 1;
    const target = await ctx.db.getDoc(`users/${targetUid}`);
    await sendTo(ctx, plannerUid, buildVoiceUndeliveredMessage({
      title: item.title,
      targetName: target && target.name ? String(target.name) : null,
      targetUid,
      itemId,
    }), summary);
  }
  return summary;
}
