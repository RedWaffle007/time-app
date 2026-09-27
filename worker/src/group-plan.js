// Group plans that met a double-booked member (Batch G item 4, 2026-09-27).
// DECISIONS.md "No double-booking — minute locks".
//
// The planner's app sends ONE plan per member; a member whose minute is
// already held by a live plan is refused by the rules and gets no alarm. The
// app then POSTs { event: 'groupPlanned', groupId, title, setCount, busy } —
// `busy` being the members it could not set, each with the instant it tried.
//
// Nothing the phone claims is trusted. A member counts as busy ONLY if the
// minute lock at that instant names a plan that is still live and was NOT
// made by this planner for this group (otherwise a planner could send false
// "busy" notices, or claim a member they just planned). Verified members get
//   "Group task "{task}" from {planner} wasn't set for you at {time} — you
//    already have a plan then."
// with {time} in THEIR home zone (12-hour: the Worker cannot see a phone's
// 12/24-hour setting). If anyone was busy, the planner gets the summary
//   "Your group task "{task}" is set for {X} members. {Y} ({names}) were busy
//    at that time and won't be alerted."
// Each member is told at most once per plan minute (`groupBusyNotices`).

import { ACTIVITY_CHANNEL_ID, bothInGroup } from './notify.js';

const MAX_BUSY = 50;
const MAX_TITLE = 200;

export function epochMinute(instant) {
  return String(Math.floor(instant.getTime() / 60000));
}

export function formatTimeIn(instant, timeZone) {
  let text;
  try {
    text = new Intl.DateTimeFormat('en-US', {
      timeZone, hour: 'numeric', minute: '2-digit',
    }).format(instant);
  } catch {
    text = new Intl.DateTimeFormat('en-US', {
      timeZone: 'UTC', hour: 'numeric', minute: '2-digit', timeZoneName: 'short',
    }).format(instant);
  }
  // Newer ICU puts a narrow no-break space before AM/PM; push bodies read
  // better (and test stably) with a plain one.
  return text.replace(/\u202f/g, ' ');
}

function isLive(item) {
  return Boolean(item)
    && (item.outcome === undefined || item.outcome === null)
    && (item.status === 'pending' || item.status === 'approved');
}

function cleanTitle(title) {
  return String(title || '').replace(/\s+/g, ' ').trim().slice(0, MAX_TITLE) || 'a task';
}

export function busyMemberMessage({ title, plannerName, time }) {
  return {
    title: 'Group task not set',
    body: `Group task "${title}" from ${plannerName} wasn't set for you at ${time}. You already have a plan then.`,
  };
}

export function plannerSummaryMessage({ title, setCount, busyNames }) {
  const y = busyNames.length;
  return {
    title: 'Group task set',
    body: `Your group task "${title}" is set for ${setCount} ${setCount === 1 ? 'member' : 'members'}. `
      + `${y} (${busyNames.join(', ')}) ${y === 1 ? 'was' : 'were'} busy at that time and won't be alerted.`,
  };
}

async function pushTo(ctx, uid, notification, data) {
  const tokens = await ctx.db.listDocIds(`users/${uid}/fcmTokens`);
  let sent = 0;
  for (const token of tokens) {
    const res = await ctx.fcm.send(token, {
      notification,
      android: { priority: 'high', notification: { channel_id: ACTIVITY_CHANNEL_ID } },
      data,
    });
    if (res.ok) sent += 1;
    else if (res.error === 'UNREGISTERED' || res.error === 'INVALID') {
      await ctx.db.deleteDoc(`users/${uid}/fcmTokens/${token}`);
    }
  }
  return sent;
}

/**
 * `ctx = { db, fcm, now }`. Returns `{ status, body }`; body.busyUids lists
 * the members the Worker VERIFIED as busy (the app shows these names).
 */
export async function handleGroupPlanned(ctx, callerUid, body) {
  const { groupId, title, setCount, busy } = body || {};
  if (typeof groupId !== 'string' || !groupId || groupId.includes('/')
    || !Array.isArray(busy) || busy.length > MAX_BUSY
    || !Number.isInteger(setCount) || setCount < 0) {
    return { status: 400, body: { error: 'invalid-body' } };
  }
  const group = await ctx.db.getDoc(`groups/${groupId}`);
  const members = group && Array.isArray(group.memberUids) ? group.memberUids : [];
  if (!members.includes(callerUid)) return { status: 403, body: { error: 'forbidden' } };

  const task = cleanTitle(title);
  const planner = await ctx.db.getDoc(`users/${callerUid}`);
  const plannerName = planner && planner.name ? String(planner.name) : 'A group member';
  const now = ctx.now || new Date();

  const verified = await verifyBusyMembers(ctx, callerUid, groupId, busy, {
    now,
    // After Send: a member holding THIS plan (the planner's own copy for this
    // group) is not busy with anything else.
    ignoreOwnGroupPlan: true,
  });

  let sent = 0;
  for (const m of verified) {
    const noticePath = `groupBusyNotices/${groupId}_${callerUid}_${m.uid}_${m.minute}`;
    if (await ctx.db.getDoc(noticePath)) continue;
    const n = await pushTo(ctx, m.uid, busyMemberMessage({
      title: task, plannerName, time: formatTimeIn(m.instant, m.zone),
    }), { type: 'groupBusy', event: 'groupBusy', groupId });
    if (n > 0) {
      await ctx.db.patchDoc(noticePath, { sentAt: now.toISOString() });
      sent += n;
    }
  }

  if (verified.length > 0) {
    sent += await pushTo(ctx, callerUid, plannerSummaryMessage({
      title: task, setCount, busyNames: verified.map((m) => m.name),
    }), { type: 'groupPlanSummary', event: 'groupPlanSummary', groupId });
  }

  return {
    status: 200,
    body: { sent, busyUids: verified.map((m) => m.uid) },
  };
}

/**
 * The members of [entries] (`{ uid, instantUtc }`) who are VERIFIED busy: the
 * minute lock at that instant names a plan that is still live. Shared by the
 * after-Send report and the before-Send preview so both judge alike.
 */
async function verifyBusyMembers(ctx, callerUid, groupId, entries, {
  now, ignoreOwnGroupPlan,
}) {
  const verified = [];
  const seen = new Set();
  for (const entry of entries) {
    const uid = entry && entry.uid;
    const instant = new Date(entry && entry.instantUtc);
    if (typeof uid !== 'string' || !uid || uid.includes('/') || uid === callerUid
      || seen.has(uid) || Number.isNaN(instant.getTime())) continue;
    seen.add(uid);
    // Only plans still ahead (with a little slack for the round trip).
    if (instant.getTime() < now.getTime() - 5 * 60 * 1000) continue;
    if (!(await bothInGroup(ctx.db, groupId, callerUid, uid))) continue;

    const minute = epochMinute(instant);
    const lock = await ctx.db.getDoc(`scheduleMinutes/${uid}/minutes/${minute}`);
    if (!lock || typeof lock.itemId !== 'string') continue;
    const holder = await ctx.db.getDoc(`scheduleItems/${uid}/items/${lock.itemId}`);
    if (!isLive(holder)) continue;
    if (ignoreOwnGroupPlan
      && holder.createdByUid === callerUid && holder.groupId === groupId) continue;

    const member = await ctx.db.getDoc(`users/${uid}`);
    verified.push({
      uid,
      name: member && member.name ? String(member.name) : 'A member',
      zone: member && member.homeTimezone ? String(member.homeTimezone) : 'UTC',
      instant,
      minute,
    });
  }
  return verified;
}

/**
 * Before Send (2026-09-27, group voice notes): which members are busy at the
 * chosen minute, so the sheet can say "Rings for 5 · Busy: 2" up front. A
 * non-friend member's schedule is unreadable from the phone, so the Worker
 * answers, with the SAME check as the after-Send report and NO pushes. It
 * reveals only what Send would reveal anyway, and only to a fellow member.
 * Body: `{ event: 'groupAvailability', groupId, members: [{uid, instantUtc}] }`.
 */
export async function handleGroupAvailability(ctx, callerUid, body) {
  const { groupId, members } = body || {};
  if (typeof groupId !== 'string' || !groupId || groupId.includes('/')
    || !Array.isArray(members) || members.length > MAX_BUSY) {
    return { status: 400, body: { error: 'invalid-body' } };
  }
  const group = await ctx.db.getDoc(`groups/${groupId}`);
  const roster = group && Array.isArray(group.memberUids) ? group.memberUids : [];
  if (!roster.includes(callerUid)) return { status: 403, body: { error: 'forbidden' } };
  const busy = await verifyBusyMembers(ctx, callerUid, groupId, members, {
    now: ctx.now || new Date(),
    ignoreOwnGroupPlan: false,
  });
  return { status: 200, body: { busyUids: busy.map((m) => m.uid) } };
}
