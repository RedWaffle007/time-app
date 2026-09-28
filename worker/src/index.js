// index.js — the Cloudflare Worker entry point. It is a THIN transport shell:
// authenticate the caller, authorize them against the item, build a REST-backed
// ctx, and hand off to the shared notify.js module. All notification policy
// (recipients, payload, dedup, cleanup) lives in notify.js so a future Cloud
// Function reuses it unchanged.
//
// Hardening:
//   - POST only (else 405).
//   - request body capped (else 413).
//   - Firebase ID token required + verified (else 401).
//   - verified caller must BE the item's target (else 403).
//   - fails CLOSED: any Firestore/FCM/setup error → 500, nothing half-sent.

import { verifyFirebaseIdToken, IdTokenError } from './verify-id-token.js';
import { getAccessToken } from './google-auth.js';
import { makeFirestoreDb } from './firestore-rest.js';
import { makeFcm } from './fcm-rest.js';
import {
  sendEventNotification,
  sendFriendNotification,
  FRIEND_EVENTS,
  ITEM_EVENTS,
  groupAdminUids,
} from './notify.js';
import {
  handleAvatarUpload,
  handleAvatarDelete,
  handleGroupAvatarUpload,
  handleGroupAvatarDelete,
} from './avatar.js';
import { sendDueInactivityNotifications } from './inactivity.js';
import { handleGroupAvailability, handleGroupPlanned } from './group-plan.js';
import { sendPlanRequestReminders } from './plan-request-reminders.js';
import { expirePlanRequests } from './plan-request-expiry.js';
import { settleLapsedItems } from './lapse.js';
import { rescueUndeliveredVoiceNotes } from './voice-rescue.js';
import { handleInviteRequest } from './invite.js';
import { ALARM_TIMEOUT_EVENT, recordAlarmTimeout } from './alarm-timeout.js';
import {
  MAX_VOICE_BYTES,
  makeVoiceStorage,
  sweepVoiceUploads,
  voiceCopy,
  voiceDownload,
  voiceUpload,
} from './voice.js';
import {
  libraryAttach,
  libraryDelete,
  libraryDownload,
  saveSentVoiceNote,
} from './voice-library.js';

const MAX_BODY_BYTES = 2048;
// The item events come from notify.js — one list, so the door and the policy
// can never disagree again (this copy once lacked `unavailable`, 400-ing it).
const EVENTS = ITEM_EVENTS;
// Planner-triggered events (caller must be the item's CREATOR); the rest are
// target-triggered (caller must be the target). This is the authz branch the
// "one endpoint" framing requires — one endpoint, but NOT one authz rule.
const PLANNER_TRIGGERED = new Set(['created', 'withdrawn']);

export default {
  async fetch(request, env, execCtx) {
    // --- routing ---
    //
    // Two features share one Worker: push (the root path, unchanged) and
    // picture storage (`/avatar` and `/group-avatar`). One Worker rather than
    // two because
    // both need exactly the same thing — a verified Firebase ID token and a
    // privileged credential that must never reach a phone — and that
    // verification code is not worth duplicating or keeping in step.
    //
    // The avatar routes are handled BEFORE the POST-only guard below, because
    // removing a picture is a DELETE.
    const url = new URL(request.url);
    // Invite links + Android App Links verification: public GETs, no auth,
    // handled before every other route (item 17).
    const invite = handleInviteRequest(request, env);
    if (invite) return invite;

    if (url.pathname === '/voice' || url.pathname.startsWith('/voice/')) {
      return handleVoiceRequest(request, env, url);
    }

    if (url.pathname === '/avatar') {
      if (request.method !== 'POST' && request.method !== 'DELETE') {
        return json({ error: 'method-not-allowed' }, 405, {
          Allow: 'POST, DELETE',
        });
      }
      let uid;
      try {
        uid = await requireUid(request, env.PROJECT_ID);
      } catch (e) {
        if (e instanceof IdTokenError) {
          return json({ error: 'unauthorized' }, 401);
        }
        throw e;
      }
      try {
        return request.method === 'POST'
          ? await handleAvatarUpload(request, env, uid)
          : await handleAvatarDelete(request, env, uid);
      } catch (e) {
        // Fail closed, same as the push path: never a partial result.
        // Do not serialise an exception to the app: an upstream exception can
        // include storage/provider detail that belongs only in Worker logs.
        console.error('avatar handler failed', {
          operation: request.method === 'POST' ? 'upload' : 'delete',
          name: e?.name || 'Error',
        });
        return json(
          { error: 'avatar-failed' },
          500,
        );
      }
    }

    if (url.pathname === '/group-avatar') {
      if (request.method !== 'POST' && request.method !== 'DELETE') {
        return json({ error: 'method-not-allowed' }, 405, {
          Allow: 'POST, DELETE',
        });
      }
      return handleGroupAvatarRequest(request, env);
    }

    if (request.method !== 'POST') {
      return json({ error: 'method-not-allowed' }, 405, { Allow: 'POST' });
    }

    // Reject oversized bodies before reading them.
    const declaredLen = Number(request.headers.get('content-length') || '0');
    if (declaredLen > MAX_BODY_BYTES) {
      return json({ error: 'payload-too-large' }, 413);
    }

    const raw = await request.text();
    if (raw.length > MAX_BODY_BYTES) {
      return json({ error: 'payload-too-large' }, 413);
    }

    let body;
    try {
      body = JSON.parse(raw);
    } catch {
      return json({ error: 'invalid-json' }, 400);
    }

    // Friend-graph events use a different body shape (no itemId) and a different
    // authz rule, so they are handled here — the item path below is left exactly
    // as it was, and proven.
    if (FRIEND_EVENTS.has(body && body.event)) {
      return handleFriendEvent(request, env, body);
    }

    // The target's phone, the moment its alarm rang out (alarm-timeout.js).
    if (body && body.event === ALARM_TIMEOUT_EVENT) {
      return handleAlarmTimeout(request, env, body);
    }

    // Item 4: a group plan that met double-booked members (group-plan.js).
    if (body && body.event === 'groupPlanned') {
      return handleGroupPlannedRoute(request, env, body);
    }
    if (body && body.event === 'groupAvailability') {
      return handleGroupPlannedRoute(request, env, body, handleGroupAvailability);
    }

    const { event, targetUid, itemId } = body || {};
    if (
      typeof targetUid !== 'string' ||
      typeof itemId !== 'string' ||
      !EVENTS.has(event)
    ) {
      return json({ error: 'invalid-body' }, 400);
    }

    // --- authenticate: verify the Firebase ID token ---
    const authz = request.headers.get('authorization') || '';
    const idToken = authz.startsWith('Bearer ') ? authz.slice(7).trim() : '';
    if (!idToken) return json({ error: 'missing-token' }, 401);

    const projectId = env.PROJECT_ID;
    let callerUid;
    try {
      callerUid = await verifyFirebaseIdToken(idToken, projectId);
    } catch (e) {
      if (e instanceof IdTokenError) return json({ error: 'unauthorized' }, 401);
      throw e; // unexpected → fail closed via the 500 handler below
    }

    let serviceAccount;
    try {
      serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
    } catch {
      return json({ error: 'server-misconfigured' }, 500);
    }

    try {
      const accessToken = await getAccessToken(serviceAccount);
      const db = makeFirestoreDb(projectId, accessToken);

      // --- authorize: which party may trigger THIS event ---
      // Planner-triggered (created/withdrawn): caller must be the creator.
      // Target-triggered (decided/outcome):   caller must be the target.
      // Either way the path's targetUid must match the item, so a caller can't
      // aim the push at an item under a different target's subtree.
      const item = await db.getDoc(`scheduleItems/${targetUid}/items/${itemId}`);
      if (!item) return json({ error: 'item-not-found' }, 404);
      const requiredCaller = PLANNER_TRIGGERED.has(event)
        ? item.createdByUid
        : item.targetUid;
      if (item.targetUid !== targetUid || requiredCaller !== callerUid) {
        return json({ error: 'forbidden' }, 403);
      }

      const ctx = {
        projectId,
        db,
        fcm: makeFcm(projectId, accessToken),
      };
      const res = await sendEventNotification(ctx, { event, targetUid, itemId });
      // Every SENT voice note goes into the planner's library (32d). Never
      // allowed to fail — or DELAY — the push: the copy (download + upload +
      // Firestore) runs AFTER the response via waitUntil. Awaiting it here kept
      // the planner's Send spinning past the app's 10 s timeout (2026-09-27).
      // The hourly sweep retries a copy that did not finish.
      if (event === 'created' && item.voiceNote && item.createdByUid !== targetUid) {
        const save = (async () => {
          try {
            const storage = makeVoiceStorage(env);
            if (storage.configured) {
              const saved = await saveSentVoiceNote(
                { db, storage },
                { targetUid, itemId, item },
              );
              console.log(JSON.stringify({ event: 'voice-library-save', saved }));
            }
          } catch (e) {
            console.error('voice library save failed', { name: e?.name || 'Error' });
          }
        })();
        if (execCtx && typeof execCtx.waitUntil === 'function') {
          execCtx.waitUntil(save);
        } else {
          await save;
        }
      }
      // Surface the decisive result in `wrangler tail` — HTTP 200 alone can't
      // distinguish a real send from a "nothing to send" reason (no-tokens,
      // already-notified, no-active-grant, …); the body's `reason`/`sent` can.
      console.log(JSON.stringify(res));
      return json(res, 200);
    } catch (e) {
      // Fail closed — never emit a partial/half-formed push on error.
      return json({ error: 'send-failed', detail: String(e && e.message) }, 500);
    }
  },
  async scheduled(controller, env, ctx) {
    const now = new Date(controller.scheduledTime);
    const job = cronJobFor(controller.cron);
    const run = job === 'lapse'
      ? runLapseCron(env, now)
      : job === 'voiceSweep'
        ? runVoiceSweepCron(env, now)
        : runInactivityCron(env, now);
    ctx.waitUntil(run);
  },
};

async function handleGroupAvatarRequest(request, env) {
  const groupId = request.headers.get('x-group-id') || '';
  if (!groupId || groupId.includes('/')) {
    return json({ error: 'invalid-group' }, 400);
  }

  let uid;
  try {
    uid = await requireUid(request, env.PROJECT_ID);
  } catch (e) {
    if (e instanceof IdTokenError) return json({ error: 'unauthorized' }, 401);
    throw e;
  }

  let serviceAccount;
  try {
    serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
  } catch {
    return json({ error: 'server-misconfigured' }, 500);
  }

  try {
    const accessToken = await getAccessToken(serviceAccount);
    const db = makeFirestoreDb(env.PROJECT_ID, accessToken);
    const group = await db.getDoc(`groups/${groupId}`);
    const denial = groupAvatarAuthorization(group, uid);
    if (denial) return json({ error: denial.error }, denial.status);
    return request.method === 'POST'
      ? await handleGroupAvatarUpload(request, env, groupId)
      : await handleGroupAvatarDelete(request, env, groupId);
  } catch (e) {
    console.error('group avatar handler failed', {
      operation: request.method === 'POST' ? 'upload' : 'delete',
      name: e?.name || 'Error',
    });
    return json({ error: 'avatar-failed' }, 500);
  }
}

export function groupAvatarAuthorization(group, uid) {
  if (!group) return { error: 'group-not-found', status: 404 };
  if (group.ownerUid !== uid) return { error: 'forbidden', status: 403 };
  return null;
}

// wrangler.toml declares the schedules; each invocation carries its own cron
// string. Anything unrecognised keeps the original inactivity behaviour.
// (The every-minute approval-reminder cron was removed with approval, F2.)
export const LAPSE_CRON = '*/2 * * * *';
export const VOICE_SWEEP_CRON = '7 * * * *';
export function cronJobFor(cron) {
  if (cron === LAPSE_CRON) return 'lapse';
  if (cron === VOICE_SWEEP_CRON) return 'voiceSweep';
  return 'inactivity';
}

/**
 * Voice-note routes (item 32a). POST /voice uploads; GET
 * /voice/{targetUid}/{itemId} downloads. Both need a verified ID token; the
 * policy (voice.js) re-checks everything against Firestore.
 */
async function handleVoiceRequest(request, env, url) {
  const isUpload = url.pathname === '/voice';
  const isAttach = url.pathname === '/voice/attach';
  const isCopy = url.pathname === '/voice/copy';
  const libraryMatch = /^\/voice\/library\/([^/]+)$/.exec(url.pathname);
  const allowed = isUpload || isAttach || isCopy
    ? ['POST']
    : libraryMatch ? ['GET', 'DELETE'] : ['GET'];
  if (!allowed.includes(request.method)) {
    return json({ error: 'method-not-allowed' }, 405, { Allow: allowed.join(', ') });
  }
  const storage = makeVoiceStorage(env);
  if (!storage.configured) return json({ error: 'storage-not-configured' }, 500);
  if (isUpload) {
    const declared = Number(request.headers.get('content-length') || '0');
    if (declared > MAX_VOICE_BYTES) return json({ error: 'too-large' }, 413);
  }

  let callerUid;
  try {
    callerUid = await requireUid(request, env.PROJECT_ID);
  } catch (e) {
    if (e instanceof IdTokenError) return json({ error: 'unauthorized' }, 401);
    throw e;
  }
  let serviceAccount;
  try {
    serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
  } catch {
    return json({ error: 'server-misconfigured' }, 500);
  }

  try {
    const accessToken = await getAccessToken(serviceAccount);
    const ctx = { db: makeFirestoreDb(env.PROJECT_ID, accessToken), storage };
    if (isAttach) {
      const res = await libraryAttach(ctx, {
        callerUid,
        noteId: request.headers.get('x-note-id') || '',
        targetUid: request.headers.get('x-target-uid') || '',
        itemId: request.headers.get('x-item-id') || '',
        groupId: request.headers.get('x-group-id') || '',
      });
      return json(res.body, res.status);
    }
    if (isCopy) {
      const res = await voiceCopy(ctx, {
        callerUid,
        fromItemId: request.headers.get('x-from-item-id') || '',
        targetUid: request.headers.get('x-target-uid') || '',
        itemId: request.headers.get('x-item-id') || '',
        groupId: request.headers.get('x-group-id') || '',
      });
      return json(res.body, res.status);
    }
    if (libraryMatch && request.method === 'DELETE') {
      const res = await libraryDelete(ctx, { callerUid, noteId: libraryMatch[1] });
      return json(res.body, res.status);
    }
    if (isUpload) {
      const bytes = new Uint8Array(await request.arrayBuffer());
      const res = await voiceUpload(ctx, {
        callerUid,
        targetUid: request.headers.get('x-target-uid') || '',
        itemId: request.headers.get('x-item-id') || '',
        groupId: request.headers.get('x-group-id') || '',
        bytes,
      });
      return json(res.body, res.status);
    }
    const [, , targetUid, itemId] = url.pathname.split('/');
    const res = libraryMatch
      ? await libraryDownload(ctx, { callerUid, noteId: libraryMatch[1] })
      : await voiceDownload(ctx, { callerUid, targetUid, itemId });
    if (!res.bytes) return json(res.body, res.status);
    return new Response(res.bytes, {
      status: 200,
      headers: {
        'Content-Type': 'audio/mp4',
        'Cache-Control': 'private, no-store',
        ETag: `"${res.sha256}"`,
      },
    });
  } catch (e) {
    console.error('voice handler failed', { name: e?.name || 'Error' });
    return json({ error: 'voice-failed' }, 500);
  }
}

async function runVoiceSweepCron(env, now) {
  let serviceAccount;
  try {
    serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
  } catch {
    throw new Error('server-misconfigured');
  }
  const accessToken = await getAccessToken(serviceAccount);
  const ctx = {
    db: makeFirestoreDb(env.PROJECT_ID, accessToken),
    storage: makeVoiceStorage(env),
  };
  ctx.saveToLibrary = (args, at) => saveSentVoiceNote(ctx, args, at);
  const result = await sweepVoiceUploads(ctx, now);
  console.log(JSON.stringify({ event: 'voice-sweep-cron', ...result }));
}

async function runLapseCron(env, now) {
  let serviceAccount;
  try {
    serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
  } catch {
    throw new Error('server-misconfigured');
  }
  const accessToken = await getAccessToken(serviceAccount);
  const context = {
    projectId: env.PROJECT_ID,
    db: makeFirestoreDb(env.PROJECT_ID, accessToken),
    fcm: makeFcm(env.PROJECT_ID, accessToken),
  };
  const result = await settleLapsedItems(context, now);
  console.log(JSON.stringify({ event: 'lapse-cron', ...result }));
  // Same 2-minute invocation: rescue voice notes not yet on the target's phone.
  const rescue = await rescueUndeliveredVoiceNotes(context, now);
  console.log(JSON.stringify({ event: 'voice-rescue', ...rescue }));
  // …and remind friends of plan requests they have not planned yet (item 5).
  const reminders = await sendPlanRequestReminders(context, now);
  console.log(JSON.stringify({ event: 'plan-request-reminders', ...reminders }));
  // …and close requests whose minute passed unplanned, telling both people.
  const expiry = await expirePlanRequests(context, now);
  console.log(JSON.stringify({ event: 'plan-request-expiry', ...expiry }));
}

async function runInactivityCron(env, now) {
  let serviceAccount;
  try {
    serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
  } catch {
    throw new Error('server-misconfigured');
  }
  const accessToken = await getAccessToken(serviceAccount);
  const context = {
    projectId: env.PROJECT_ID,
    db: makeFirestoreDb(env.PROJECT_ID, accessToken),
    fcm: makeFcm(env.PROJECT_ID, accessToken),
  };
  const result = await sendDueInactivityNotifications(context, now);
  console.log(JSON.stringify({ event: 'inactivity-cron', ...result }));
}

/**
 * Friend-request / friend-accept push. Same shell contract as the item path —
 * verify the ID token, build a service-account-backed db, authorize, hand off to
 * notify.js — but the AUTHZ is different: the ACTOR triggers, and only for a
 * relationship that actually exists in Firestore. A caller cannot aim a friend
 * push at an arbitrary user: `friendRequest` requires a pending request they
 * sent; `friendAccept` requires the friendship to exist. Fails CLOSED.
 */
async function handleFriendEvent(request, env, body) {
  const { event, fromUid, toUid, kind, planRequestId, groupId } = body || {};
  if (
    typeof fromUid !== 'string' ||
    typeof toUid !== 'string' ||
    !fromUid ||
    !toUid ||
    // A code join request is the candidate asking for themselves (item 3).
    (fromUid === toUid && event !== 'groupJoinRequested')
  ) {
    return json({ error: 'invalid-body' }, 400);
  }
  if (
    (event === 'groupJoinApproved' || event === 'groupJoinRequested') &&
    (typeof groupId !== 'string' || !groupId || groupId.includes('/'))
  ) {
    return json({ error: 'invalid-body' }, 400);
  }

  const projectId = env.PROJECT_ID;
  let callerUid;
  try {
    callerUid = await requireUid(request, projectId);
  } catch (e) {
    if (e instanceof IdTokenError) return json({ error: 'unauthorized' }, 401);
    throw e;
  }

  let serviceAccount;
  try {
    serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
  } catch {
    return json({ error: 'server-misconfigured' }, 500);
  }

  try {
    const accessToken = await getAccessToken(serviceAccount);
    const db = makeFirestoreDb(projectId, accessToken);

    if (event === 'friendRequest') {
      // The sender notifies the recipient — only with a real pending request
      // they own. This is the anti-abuse gate: no request, no push.
      if (callerUid !== fromUid) return json({ error: 'forbidden' }, 403);
      const req = await db.getDoc(`friendRequests/${fromUid}_${toUid}`);
      if (!req) return json({ error: 'request-not-found' }, 404);
      if (
        req.fromUid !== fromUid ||
        req.toUid !== toUid ||
        req.status !== 'pending'
      ) {
        return json({ error: 'forbidden' }, 403);
      }
    } else if (event === 'friendAccept') {
      // friendAccept: the accepter (toUid) notifies the original sender — only
      // once the friendship actually exists. Its id is the sorted pair.
      if (callerUid !== toUid) return json({ error: 'forbidden' }, 403);
      const pairId = [fromUid, toUid].sort().join('_');
      const friendship = await db.getDoc(`friendships/${pairId}`);
      if (!friendship) return json({ error: 'forbidden' }, 403);
    } else if (event === 'planRequested') {
      if (callerUid !== fromUid || typeof planRequestId !== 'string') {
        return json({ error: 'forbidden' }, 403);
      }
      const req = await db.getDoc(`planRequests/${planRequestId}`);
      if (!req) return json({ error: 'request-not-found' }, 404);
      if (
        req.requesterUid !== fromUid ||
        req.plannerUid !== toUid ||
        (req.status !== 'pending' && req.status !== 'inProgress')
      ) {
        return json({ error: 'forbidden' }, 403);
      }
    } else if (event === 'groupJoinRequested') {
      // Item 3: whoever asked (the candidate with a code, or the inviting
      // member) tells the group's admins. The pending request made by the
      // caller is re-verified in notify.js before anyone is pushed.
      if (callerUid !== fromUid) return json({ error: 'forbidden' }, 403);
    } else {
      // groupJoinApproved: an ADMIN (item 3 — only admins admit) tells the
      // admitted candidate. The request's approved state and the roster are
      // re-verified in notify.js.
      if (callerUid !== fromUid) return json({ error: 'forbidden' }, 403);
      const group = await db.getDoc(`groups/${groupId}`);
      if (!groupAdminUids(group).includes(callerUid)) {
        return json({ error: 'forbidden' }, 403);
      }
    }

    const ctx = {
      projectId,
      db,
      fcm: makeFcm(projectId, accessToken),
    };
    const res = await sendFriendNotification(ctx, {
      event, fromUid, toUid, kind, planRequestId, groupId,
    });
    console.log(JSON.stringify(res));
    return json(res, 200);
  } catch (e) {
    return json({ error: 'send-failed', detail: String(e && e.message) }, 500);
  }
}

async function handleGroupPlannedRoute(request, env, body, handler = handleGroupPlanned) {
  const projectId = env.PROJECT_ID;
  let callerUid;
  try {
    callerUid = await requireUid(request, projectId);
  } catch (e) {
    if (e instanceof IdTokenError) return json({ error: 'unauthorized' }, 401);
    throw e;
  }
  let serviceAccount;
  try {
    serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
  } catch {
    return json({ error: 'server-misconfigured' }, 500);
  }
  try {
    const accessToken = await getAccessToken(serviceAccount);
    const ctx = {
      db: makeFirestoreDb(projectId, accessToken),
      fcm: makeFcm(projectId, accessToken),
      now: new Date(),
    };
    const res = await handler(ctx, callerUid, body);
    console.log(JSON.stringify({ [body.event]: res.body }));
    return json(res.body, res.status);
  } catch (e) {
    return json({ error: 'send-failed', detail: String(e && e.message) }, 500);
  }
}

/**
 * The verified caller's uid, or throw.
 *
 * Extracted so the push route and the avatar routes authenticate identically —
 * two copies of "parse the Bearer header, verify the token" is two places for
 * an accidental `if (!token) uid = 'anonymous'` to appear.
 */
/**
 * POST / {event:'alarmTimeout', targetUid, itemId, at?} from the target's
 * phone (native, app not running). Only the item's TARGET may report; the
 * Worker records `alarm.unavailableAt` and sends the `unavailable` push.
 */
async function handleAlarmTimeout(request, env, body) {
  const { targetUid, itemId, at } = body || {};
  if (
    typeof targetUid !== 'string' ||
    typeof itemId !== 'string' ||
    !targetUid ||
    !itemId ||
    targetUid.includes('/') ||
    itemId.includes('/') ||
    (at !== undefined && typeof at !== 'number')
  ) {
    return json({ error: 'invalid-body' }, 400);
  }

  let callerUid;
  try {
    callerUid = await requireUid(request, env.PROJECT_ID);
  } catch (e) {
    if (e instanceof IdTokenError) return json({ error: 'unauthorized' }, 401);
    throw e;
  }
  if (callerUid !== targetUid) return json({ error: 'forbidden' }, 403);

  let serviceAccount;
  try {
    serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
  } catch {
    return json({ error: 'server-misconfigured' }, 500);
  }

  try {
    const accessToken = await getAccessToken(serviceAccount);
    const db = makeFirestoreDb(env.PROJECT_ID, accessToken);
    const res = await alarmTimeoutAndNotify(
      { projectId: env.PROJECT_ID, db, fcm: makeFcm(env.PROJECT_ID, accessToken) },
      { targetUid, itemId, reportedAtMs: at, nowMs: Date.now() },
    );
    console.log(JSON.stringify({ event: ALARM_TIMEOUT_EVENT, ...res }));
    return json(res, res.status || 200);
  } catch (e) {
    return json({ error: 'send-failed', detail: String(e && e.message) }, 500);
  }
}

/**
 * The testable core of [handleAlarmTimeout], after authentication: the item
 * must exist under the caller's own subtree, then the fact is recorded and
 * the planner pushed.
 */
export async function alarmTimeoutAndNotify(ctx, { targetUid, itemId, reportedAtMs, nowMs }) {
  const item = await ctx.db.getDoc(`scheduleItems/${targetUid}/items/${itemId}`);
  if (!item) return { status: 404, error: 'item-not-found' };
  if (item.targetUid !== targetUid) return { status: 403, error: 'forbidden' };
  const recorded = await recordAlarmTimeout(ctx.db, {
    targetUid,
    itemId,
    nowMs,
    reportedAtMs,
  });
  if (!recorded.ready) {
    return { recorded: false, sent: 0, reason: recorded.reason };
  }
  const push = await sendEventNotification(ctx, {
    event: 'unavailable',
    targetUid,
    itemId,
  });
  return { recorded: recorded.recorded, ...push };
}

async function requireUid(request, projectId) {
  const authz = request.headers.get('authorization') || '';
  const idToken = authz.startsWith('Bearer ') ? authz.slice(7).trim() : '';
  if (!idToken) throw new IdTokenError('missing token');
  return verifyFirebaseIdToken(idToken, projectId);
}

function json(obj, status, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...extraHeaders },
  });
}
