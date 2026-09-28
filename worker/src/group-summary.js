// Group plan summaries (2026-09-28; DECISIONS.md "Uh-Oh for every negative
// event"). A group plan is one item per member, and each member's ring,
// dismissal and missed-popup answer used to reach the planner as its own
// push. Now the planner gets LIVE lists instead, one notification per list,
// updated in place (same Android tag) the moment each member's phone reports:
//
//   list        negative?  title (default alarm / voice note)
//   missed      Uh-Oh      Didn't dismiss "{task}" / Didn't dismiss your voice note
//   dismissed   normal     Dismissed "{task}"      / Heard your voice note
//   skipped     Uh-Oh      Skipped "{task}"        (missed-popup Skip)
//   done        normal     Done "{task}"           (missed-popup Done)
//   heard       normal     —                       / Heard your voice note late
//   noResponse  Uh-Oh      Didn't respond to "{task}" / … your voice note
//
// The body lists the members' names, e.g. "Test A, Test B · Team".
//
// State lives at `groupPlanSummaries/{groupId}_{plannerUid}_{epochMinute}`
// (Worker-only: no client rule matches it, so clients are denied). Each
// member is a map entry `lists.{list}.{uid} = epochMs`, written by field path,
// so members reporting at the same instant never overwrite each other.

import { ACTIVITY_CHANNEL_ID, UNAVAILABLE_CHANNEL_ID, isVoiceAlarm } from './notify.js';

export const SUMMARY_LISTS = ['missed', 'dismissed', 'skipped', 'done', 'heard', 'noResponse'];
const UH_OH = new Set(['missed', 'skipped', 'noResponse']);

/** A member's copy of a group plan (the planner's own copy is not one). */
export function isGroupMemberCopy(item) {
  return Boolean(item && item.groupId)
    && Boolean(item.createdByUid) && item.createdByUid !== item.targetUid;
}

/** One summary per group plan: its group, its planner and its minute. */
export function summaryId(item) {
  const minute = Math.floor(Date.parse(item.scheduledInstantUtc) / 60000);
  return `${item.groupId}_${item.createdByUid}_${minute}`;
}

/**
 * Which list an item event feeds, or null (it stays an individual push).
 * Only the ring result and the MISSED-popup answers are summarised; a Done or
 * Skip after dismissing stays an individual push.
 */
export function summaryListFor(event, subtype, item) {
  if (!isGroupMemberCopy(item)) return null;
  if (!Number.isFinite(Date.parse(item.scheduledInstantUtc))) return null;
  if (event === 'unavailable') return 'missed';
  if (event === 'dismissed') return 'dismissed';
  if (event === 'outcome' && item.alarm && item.alarm.unavailableAt) {
    if (subtype === 'done') return isVoiceAlarm(item) ? 'heard' : 'done';
    if (subtype === 'skipped') return 'skipped';
  }
  return null;
}

function cleanTask(title) {
  return String(title || '').replace(/\s+/g, ' ').trim() || 'your task';
}

/** The title for [list]. Voice notes have no task name. */
export function summaryTitle(list, { voice, task }) {
  const t = `"${cleanTask(task)}"`;
  switch (list) {
    case 'missed': return voice ? "Didn't dismiss your voice note" : `Didn't dismiss ${t}`;
    case 'dismissed': return voice ? 'Heard your voice note' : `Dismissed ${t}`;
    case 'skipped': return `Skipped ${t}`;
    case 'done': return `Done ${t}`;
    case 'heard': return 'Heard your voice note late';
    case 'noResponse': return voice ? "Didn't respond to your voice note" : `Didn't respond to ${t}`;
    default: return t;
  }
}

/**
 * Who is on [list] now, in the order they reported. A member who DISMISSED
 * never also counts as not dismissing (a late report from a phone the cron
 * had already counted as silent).
 */
export function membersOn(doc, list) {
  const lists = (doc && doc.lists) || {};
  const entries = Object.entries(lists[list] || {});
  const dismissed = lists.dismissed || {};
  return entries
    .filter(([uid]) => list !== 'missed' || !(uid in dismissed))
    .sort((a, b) => Number(a[1]) - Number(b[1]))
    .map(([uid]) => uid);
}

/** The push for [list]: names in the body, one tag per list so it updates. */
export function buildSummaryMessage(list, { voice, task, names, groupName, groupId, id }) {
  const where = groupName ? ` · ${groupName}` : '';
  const uhOh = UH_OH.has(list);
  return {
    notification: {
      title: summaryTitle(list, { voice, task }),
      body: `${names.join(', ')}${where}`,
    },
    android: {
      priority: 'high',
      notification: {
        channel_id: uhOh ? UNAVAILABLE_CHANNEL_ID : ACTIVITY_CHANNEL_ID,
        tag: `group-${id}-${list}`,
      },
    },
    data: {
      type: 'groupPlanSummary',
      event: 'groupPlanSummary',
      groupId: String(groupId),
      list,
      tag: `group-${id}-${list}`,
      ...(uhOh ? { uhOh: 'true' } : {}),
    },
  };
}

/**
 * Put [memberUid] on [list] for [item]'s group plan, then return the message
 * to send (built from the lists as they now stand), or null if the list is
 * somehow empty. `now` is a Date.
 */
export async function recordAndBuildSummary(ctx, item, memberUid, list, now = new Date()) {
  const id = summaryId(item);
  const path = `groupPlanSummaries/${id}`;
  await ctx.db.patchPaths(path, {
    groupId: String(item.groupId),
    plannerUid: String(item.createdByUid),
    title: String(item.title || ''),
    voice: isVoiceAlarm(item),
    scheduledInstantUtc: String(item.scheduledInstantUtc),
    lists: { [list]: { [memberUid]: now.getTime() } },
  }, [
    'groupId', 'plannerUid', 'title', 'voice', 'scheduledInstantUtc',
    `lists.${list}.\`${memberUid}\``,
  ]);
  const doc = await ctx.db.getDoc(path);
  const uids = membersOn(doc, list);
  if (uids.length === 0) return null;
  const [group, ...users] = await Promise.all([
    ctx.db.getDoc(`groups/${item.groupId}`),
    ...uids.map((uid) => ctx.db.getDoc(`users/${uid}`)),
  ]);
  return buildSummaryMessage(list, {
    voice: isVoiceAlarm(item),
    task: item.title,
    names: users.map((u) => (u && u.name ? String(u.name) : 'A member')),
    groupName: group && group.name ? String(group.name) : '',
    groupId: item.groupId,
    id,
  });
}

/** Send [message] to every device of [uid]; dead tokens are removed. */
export async function sendToUser(ctx, uid, message) {
  const tokens = await ctx.db.listDocIds(`users/${uid}/fcmTokens`);
  let sent = 0;
  await Promise.all(tokens.map(async (token) => {
    const res = await ctx.fcm.send(token, message);
    if (res.ok) sent += 1;
    else if (res.error === 'UNREGISTERED' || res.error === 'INVALID') {
      await ctx.db.deleteDoc(`users/${uid}/fcmTokens/${token}`);
    }
  }));
  return sent;
}

// A phone that never reported (off, no signal, app data cleared) would leave
// the planner without a word until the end-of-day lapse. The 2-minute cron
// counts such members as not dismissing once the ring is well over.
export const SILENT_AFTER_MS = 3 * 60 * 1000;
const SILENT_LOOKBACK_MS = 15 * 60 * 1000;

/** `ctx = { db, fcm }`. Returns a summary for the cron log. */
export async function noteSilentGroupMembers(ctx, now = new Date()) {
  const nowMs = now.getTime();
  const rows = await ctx.db.listItemsScheduledBetween(
    'approved',
    new Date(nowMs - SILENT_LOOKBACK_MS).toISOString(),
    new Date(nowMs - SILENT_AFTER_MS).toISOString(),
    100,
  );
  const latest = new Map(); // summary id -> { item, message }
  let noted = 0;
  for (const row of rows) {
    const m = /^scheduleItems\/([^/]+)\/items\/([^/]+)$/.exec(row.path || '');
    if (!m) continue;
    const item = row.data || {};
    if (!isGroupMemberCopy(item) || item.targetUid !== m[1]) continue;
    const alarm = item.alarm || {};
    if (alarm.dismissedAt || alarm.unavailableAt || item.outcome) continue;
    const doc = await ctx.db.getDoc(`groupPlanSummaries/${summaryId(item)}`);
    const lists = (doc && doc.lists) || {};
    if ((lists.missed || {})[m[1]] || (lists.dismissed || {})[m[1]]) continue;
    const message = await recordAndBuildSummary(ctx, item, m[1], 'missed', now);
    noted += 1;
    if (message) latest.set(summaryId(item), { item, message });
  }
  let sent = 0;
  for (const { item, message } of latest.values()) {
    sent += await sendToUser(ctx, item.createdByUid, message);
  }
  return { scanned: rows.length, noted, sent };
}
