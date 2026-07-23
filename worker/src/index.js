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
import { sendOutcomeNotification } from './notify.js';

const MAX_BODY_BYTES = 2048;
const VALID_OUTCOMES = new Set(['done', 'skipped']);

export default {
  async fetch(request, env) {
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

    const { targetUid, itemId, outcome } = body || {};
    if (
      typeof targetUid !== 'string' ||
      typeof itemId !== 'string' ||
      !VALID_OUTCOMES.has(outcome)
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

      // --- authorize: the caller must be the item's target ---
      const item = await db.getDoc(`scheduleItems/${targetUid}/items/${itemId}`);
      if (!item) return json({ error: 'item-not-found' }, 404);
      if (item.targetUid !== callerUid || targetUid !== callerUid) {
        return json({ error: 'forbidden' }, 403);
      }

      const ctx = {
        projectId,
        db,
        fcm: makeFcm(projectId, accessToken),
      };
      const res = await sendOutcomeNotification(ctx, { targetUid, itemId, outcome });
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
};

function json(obj, status, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...extraHeaders },
  });
}
