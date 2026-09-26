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
} from './notify.js';
import {
  handleAvatarUpload,
  handleAvatarDelete,
  handleGroupAvatarUpload,
  handleGroupAvatarDelete,
} from './avatar.js';
import { sendDueInactivityNotifications } from './inactivity.js';
import { sendDueApprovalReminders } from './approval-reminders.js';
import { settleLapsedItems } from './lapse.js';
import { handleInviteRequest } from './invite.js';
import {
  MAX_VOICE_BYTES,
  makeVoiceStorage,
  sweepVoiceUploads,
  voiceDownload,
  voiceUpload,
} from './voice.js';

const MAX_BODY_BYTES = 2048;
const EVENTS = new Set(['created', 'decided', 'outcome', 'withdrawn', 'dismissed']);
// Planner-triggered events (caller must be the item's CREATOR); the rest are
// target-triggered (caller must be the target). This is the authz branch the
// "one endpoint" framing requires — one endpoint, but NOT one authz rule.
const PLANNER_TRIGGERED = new Set(['created', 'withdrawn']);

export default {
  async fetch(request, env) {
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
    const run = job === 'approvalReminders'
      ? runApprovalReminderCron(env, now)
      : job === 'lapse'
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

// wrangler.toml declares both schedules; each invocation carries its own cron
// string. Anything unrecognised keeps the original inactivity behaviour.
export const APPROVAL_REMINDER_CRON = '* * * * *';
export const LAPSE_CRON = '*/2 * * * *';
export const VOICE_SWEEP_CRON = '7 * * * *';
export function cronJobFor(cron) {
  if (cron === APPROVAL_REMINDER_CRON) return 'approvalReminders';
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
  if (isUpload ? request.method !== 'POST' : request.method !== 'GET') {
    return json({ error: 'method-not-allowed' }, 405, {
      Allow: isUpload ? 'POST' : 'GET',
    });
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
    const res = await voiceDownload(ctx, { callerUid, targetUid, itemId });
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
}

async function runApprovalReminderCron(env, now) {
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
  const result = await sendDueApprovalReminders(context, now);
  console.log(JSON.stringify({ event: 'approval-reminder-cron', ...result }));
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
    fromUid === toUid
  ) {
    return json({ error: 'invalid-body' }, 400);
  }
  const isPlanning = event === 'planningRequest' || event === 'planningApprove';
  if (isPlanning && kind !== 'normal' && kind !== 'emergency') {
    return json({ error: 'invalid-body' }, 400);
  }
  if (
    event === 'groupJoinApproved' &&
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
    } else if (event === 'planningRequest') {
      // The requester notifies the target — only with a real pending planning
      // request they own, of the stated kind. No request, no push.
      if (callerUid !== fromUid) return json({ error: 'forbidden' }, 403);
      const req = await db.getDoc(`planningRequests/${fromUid}_${toUid}_${kind}`);
      if (!req) return json({ error: 'request-not-found' }, 404);
      if (
        req.fromUid !== fromUid ||
        req.toUid !== toUid ||
        req.kind !== kind ||
        req.status !== 'pending'
      ) {
        return json({ error: 'forbidden' }, 403);
      }
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
    } else if (event === 'groupJoinApproved') {
      // A current member (the approver) tells the admitted candidate. The
      // request's approved state and the roster are re-verified in notify.js;
      // here the caller must be a member other than the candidate.
      if (callerUid !== fromUid) return json({ error: 'forbidden' }, 403);
      const group = await db.getDoc(`groups/${groupId}`);
      const members = group && Array.isArray(group.memberUids)
        ? group.memberUids
        : [];
      if (!members.includes(callerUid)) return json({ error: 'forbidden' }, 403);
    } else {
      // planningApprove: the approver (toUid) notifies the original requester
      // (fromUid) — only once the GRANT actually exists (the approval wrote it).
      // planner=fromUid, target=toUid; normal → plannerGrants, emergency →
      // emergencyGrants, at the sorted friendship pair.
      if (callerUid !== toUid) return json({ error: 'forbidden' }, 403);
      const pairId = [fromUid, toUid].sort().join('_');
      const sub = kind === 'emergency' ? 'emergencyGrants' : 'plannerGrants';
      const grant = await db.getDoc(
        `friendships/${pairId}/${sub}/${fromUid}_${toUid}`,
      );
      if (!grant || grant.granted !== true) {
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

/**
 * The verified caller's uid, or throw.
 *
 * Extracted so the push route and the avatar routes authenticate identically —
 * two copies of "parse the Bearer header, verify the token" is two places for
 * an accidental `if (!token) uid = 'anonymous'` to appear.
 */
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
