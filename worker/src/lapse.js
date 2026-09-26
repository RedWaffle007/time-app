// Server-side lapse (item 20, 2026-09-26): an item nobody answered is settled
// at its response deadline even if the target never opens the app, and BOTH
// people are told when it is skipped. The client's ItemLapseReconciler stays
// as an idempotent fallback; whichever writes first wins (the Worker's write
// is conditional on the item being unchanged since it was queried).
//
// The deadline MUST match `responseDeadlineUtc` in
// lib/features/scheduling/application/item_lapse_policy.dart: the later of
// midnight ending the item's own local day and scheduled time + 2 h.

import { ACTIVITY_CHANNEL_ID, itemGrantPath } from './notify.js';

export const MIN_RESPONSE_WINDOW_MS = 2 * 60 * 60 * 1000;
export const LAPSED_SKIP_REASON = 'Did not respond';
export const LAPSED_REJECT_REASON = 'Not approved in time';

// Items are only looked at between their earliest possible deadline (two hours
// after the scheduled time) and this far back. Anything older was already
// settled by a previous run or by the client.
const LOOKBACK_MS = 50 * 60 * 60 * 1000;

// ~10 subrequests per skip (claim, names, grant, group, tokens, sends), 1 per
// reject; Cloudflare's free plan allows 50 per invocation.
// The voice-note rescue shares this invocation (item 32c), so the lapse caps
// leave it room: 2 × ~10 + 6 × 1 + rescue ~15 stays under 50.
export const MAX_SKIPS_PER_RUN = 2;
export const MAX_REJECTS_PER_RUN = 6;
export const LAPSE_SCAN_LIMIT = 100;

/** Wall-clock parts of [ms] in [timeZone]; throws RangeError for a bad zone. */
function localParts(ms, timeZone) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
    hour: 'numeric',
    minute: 'numeric',
    second: 'numeric',
  }).formatToParts(new Date(ms));
  const get = (type) => Number(parts.find((p) => p.type === type).value);
  return {
    year: get('year'),
    month: get('month'),
    day: get('day'),
    hour: get('hour'),
    minute: get('minute'),
    second: get('second'),
  };
}

/** Offset of [timeZone] from UTC at instant [ms], in ms. */
function offsetAt(ms, timeZone) {
  const p = localParts(ms, timeZone);
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return asUtc - Math.floor(ms / 1000) * 1000;
}

/**
 * The instant local midnight ENDS the local day containing [scheduledMs] in
 * [timeZone]. An unknown zone falls back to the next UTC midnight, exactly
 * like the client (never immortal, never early on a guess).
 */
export function endOfLocalDayMs(scheduledMs, timeZone) {
  let p;
  try {
    p = localParts(scheduledMs, timeZone);
  } catch {
    const d = new Date(scheduledMs);
    return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1);
  }
  // Local midnight of the next calendar day, first read as if it were UTC,
  // then corrected by the zone's offset AT that midnight (two passes settle
  // DST days, where the offset at the guess differs from the final one).
  const wall = Date.UTC(p.year, p.month - 1, p.day + 1, 0, 0, 0);
  let guess = wall - offsetAt(wall, timeZone);
  guess = wall - offsetAt(guess, timeZone);
  return guess;
}

/** Later of end-of-local-day and scheduled + 2 h (mirrors the client). */
export function responseDeadlineMs(scheduledMs, timeZone) {
  return Math.max(
    endOfLocalDayMs(scheduledMs, timeZone),
    scheduledMs + MIN_RESPONSE_WINDOW_MS,
  );
}

function taskTitle(item) {
  return (item.title || 'your scheduled item').toString();
}

function label(item, groupName) {
  const isGroup = typeof groupName === 'string';
  const noun = isGroup ? 'group task' : 'task';
  const title = item.tier === 'emergency' ? `Emergency ${noun}` : noun;
  return `${title[0].toUpperCase()}${title.slice(1)} skipped automatically`;
}

/** The target's notification (they are the one who didn't respond). */
export function buildTargetLapseMessage(
  item, { plannerName, groupName, selfPlanned }, targetUid, itemId,
) {
  const task = taskTitle(item);
  const where = groupName ? ` in ${groupName}` : '';
  const body = selfPlanned
    ? `${task} was marked Skipped because you didn't respond in time.`
    : `${task}, planned by ${plannerName || 'Someone'}${where}, was marked Skipped because you didn't respond in time.`;
  return lapseMessage(label(item, groupName), body, targetUid, itemId, 'target');
}

/** The planner's notification. */
export function buildPlannerLapseMessage(
  item, { targetName, groupName }, targetUid, itemId,
) {
  const where = groupName ? ` in ${groupName}` : '';
  const body = `${targetName || 'Someone'} didn't respond to ${taskTitle(item)}${where}, so it was marked Skipped.`;
  return lapseMessage(label(item, groupName), body, targetUid, itemId, 'planner');
}

function lapseMessage(title, body, targetUid, itemId, audience) {
  return {
    notification: { title, body },
    data: { type: 'lapsed', event: 'lapsed', audience, targetUid, itemId },
    android: {
      priority: 'high',
      notification: { channel_id: ACTIVITY_CHANNEL_ID },
    },
  };
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

function parseRow(row, status) {
  const match = /^scheduleItems\/([^/]+)\/items\/([^/]+)$/.exec(row.path || '');
  if (!match || !row.updateTime) return null;
  const [, targetUid, itemId] = match;
  const item = row.data || {};
  if (item.status !== status || item.targetUid !== targetUid) return null;
  const scheduledMs = Date.parse(item.scheduledInstantUtc);
  if (!Number.isFinite(scheduledMs)) return null;
  return { targetUid, itemId, item, scheduledMs, path: `scheduleItems/${targetUid}/items/${itemId}` };
}

/**
 * One cron pass. `ctx.db.listItemsScheduledBetween(status, fromIso, toIso,
 * limit)` returns `{ path, data, updateTime }` for items with that status
 * scheduled in (from, to], soonest first.
 */
export async function settleLapsedItems(ctx, now = new Date(), {
  maxSkips = MAX_SKIPS_PER_RUN,
  maxRejects = MAX_REJECTS_PER_RUN,
} = {}) {
  const nowMs = now.getTime();
  const from = new Date(nowMs - LOOKBACK_MS).toISOString();
  const to = new Date(nowMs - MIN_RESPONSE_WINDOW_MS).toISOString();
  const summary = { rejected: 0, skipped: 0, sent: 0, cleaned: 0 };

  // Pending → Rejected "Not approved in time". Silent, as on the client.
  const pending = await ctx.db.listItemsScheduledBetween('pending', from, to, LAPSE_SCAN_LIMIT);
  for (const row of pending) {
    if (summary.rejected >= maxRejects) break;
    const parsed = parseRow(row, 'pending');
    if (!parsed) continue;
    if (responseDeadlineMs(parsed.scheduledMs, parsed.item.timezone) > nowMs) continue;
    const ok = await ctx.db.patchDocIfUnchanged(parsed.path, {
      status: 'rejected',
      rejectionReason: LAPSED_REJECT_REASON,
      decidedAt: now,
      updatedAt: now,
    }, row.updateTime);
    if (ok) summary.rejected += 1;
  }

  // Approved with no outcome → Skipped "Did not respond", and both are told.
  const approved = await ctx.db.listItemsScheduledBetween('approved', from, to, LAPSE_SCAN_LIMIT);
  for (const row of approved) {
    if (summary.skipped >= maxSkips) break;
    const parsed = parseRow(row, 'approved');
    if (!parsed || parsed.item.outcome) continue;
    const { targetUid, itemId, item } = parsed;
    if (responseDeadlineMs(parsed.scheduledMs, item.timezone) > nowMs) continue;

    // Claim by writing the outcome only if nothing changed since the query —
    // a Done/Skip (or the client's own lapse) in between wins, silently.
    const claimed = await ctx.db.patchDocIfUnchanged(parsed.path, {
      outcome: {
        result: 'skipped',
        skippedAt: now,
        skipReason: LAPSED_SKIP_REASON,
      },
      updatedAt: now,
      lapsedByServerAt: now,
    }, row.updateTime);
    if (!claimed) continue;
    summary.skipped += 1;

    const plannerUid = item.createdByUid;
    const selfPlanned = !plannerUid || plannerUid === targetUid;
    const group = item.groupId ? await ctx.db.getDoc(`groups/${item.groupId}`) : null;
    const groupName = item.groupId
      ? (group && group.name ? String(group.name) : '')
      : null;

    const planner = selfPlanned ? null : await ctx.db.getDoc(`users/${plannerUid}`);
    await sendToUser(ctx, targetUid, buildTargetLapseMessage(item, {
      plannerName: planner && planner.name ? String(planner.name) : null,
      groupName,
      selfPlanned,
    }, targetUid, itemId), summary);

    if (selfPlanned) continue;
    // Like every item push: a revoked grant means the planner is not told.
    const grant = await ctx.db.getDoc(itemGrantPath(item, plannerUid, targetUid));
    if (!grant || grant.granted !== true) continue;
    const target = await ctx.db.getDoc(`users/${targetUid}`);
    await sendToUser(ctx, plannerUid, buildPlannerLapseMessage(item, {
      targetName: target && target.name ? String(target.name) : null,
      groupName,
    }, targetUid, itemId), summary);
  }

  return summary;
}
