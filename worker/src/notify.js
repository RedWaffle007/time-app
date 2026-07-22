// notify.js — the portable, transport-agnostic completion→planner push logic.
//
// THIS FILE HOLDS ALL THE POLICY. It must not import anything Cloudflare- or
// HTTP-specific. Both callers give it the same `ctx` interface:
//   - the Cloudflare Worker builds `ctx` over Firestore REST + FCM v1 REST;
//   - a future Firestore-triggered Cloud Function builds `ctx` over the Admin
//     SDK — and reuses THIS function verbatim (the card-day swap; see
//     DECISIONS.md "Completion→planner push").
//
// ctx = {
//   projectId: string,
//   db: {
//     getDoc(path)               -> object | null    (decoded fields, plain JS)
//     listDocIds(collectionPath) -> string[]         (child doc ids only)
//     deleteDoc(path)            -> void
//     patchDoc(path, fields)     -> void             (merge-writes given fields)
//   },
//   fcm: {
//     send(token, message)       -> { ok: true } | { error: 'UNREGISTERED' | 'INVALID' | 'OTHER' }
//   },
// }
//
// args = { targetUid, itemId, outcome }  where outcome is a POINTER, not truth —
// the real outcome is re-read from Firestore and must match before anything sends.

const VALID_OUTCOMES = new Set(['done', 'skipped']);

/**
 * Resolve + send the completion/skip push for one item. Fails CLOSED: if any
 * lookup throws, it propagates (the caller returns an error) and NO push goes
 * out. A "nothing to send" condition (already-notified, no active grant, outcome
 * not yet written, no recipient token) is returned as a normal result, not an
 * error — the caller should NOT retry those.
 *
 * @returns {Promise<{sent:number, cleaned:number, recipientUid:(string|null), reason:string}>}
 */
export async function sendOutcomeNotification(ctx, { targetUid, itemId, outcome }) {
  if (!targetUid || !itemId || !VALID_OUTCOMES.has(outcome)) {
    return result(0, 0, null, 'bad-args');
  }

  const itemPath = `scheduleItems/${targetUid}/items/${itemId}`;
  const item = await ctx.db.getDoc(itemPath);
  if (!item) return result(0, 0, null, 'item-not-found');

  // (2) Server-side outcome verification — trust Firestore, not the request body.
  // The item's own `outcome.result` is the source of truth; the pointer in the
  // request must agree, or we refuse to send a mismatched push.
  const actualOutcome = item.outcome && item.outcome.result;
  if (!VALID_OUTCOMES.has(actualOutcome)) {
    return result(0, 0, null, 'outcome-not-recorded');
  }
  if (actualOutcome !== outcome) {
    return result(0, 0, null, 'outcome-mismatch');
  }

  // (1) Duplicate / replay guard — cheap: a field already read off the item.
  // Once we've delivered an outcome, re-posts of the same outcome are ignored,
  // so a killed-then-relaunched app (or a malicious re-post) can't spam.
  if (item.notifiedOutcome === actualOutcome) {
    return result(0, 0, null, 'already-notified');
  }

  // Recipient resolution — creator ∩ active-grant. Current Firestore rules only
  // entitle the item's CREATOR to read the item, so the creator is the only
  // planner who may receive its contents; the grant must still be live (revoked
  // grant ⇒ no push). If the rules ever widen to co-planner reads, THIS is the
  // one place that broadens to the full grant set — and the two must move
  // together (see DECISIONS.md).
  const plannerUid = item.createdByUid;
  const groupId = item.groupId;
  if (!plannerUid || !groupId) return result(0, 0, null, 'item-missing-fields');

  // A target planning for themselves has no planner to notify.
  if (plannerUid === targetUid) return result(0, 0, null, 'self-planned');

  const grantPath = `groups/${groupId}/plannerGrants/${plannerUid}_${targetUid}`;
  const grant = await ctx.db.getDoc(grantPath);
  if (!grant || grant.granted !== true) {
    return result(0, 0, plannerUid, 'no-active-grant');
  }

  // Recipient's registered device tokens.
  const tokens = await ctx.db.listDocIds(`users/${plannerUid}/fcmTokens`);
  if (tokens.length === 0) return result(0, 0, plannerUid, 'no-tokens');

  const message = buildMessage(item, actualOutcome, targetUid, itemId);

  let sent = 0;
  let cleaned = 0;
  for (const token of tokens) {
    const res = await ctx.fcm.send(token, message);
    if (res.ok) {
      sent += 1;
    } else if (res.error === 'UNREGISTERED' || res.error === 'INVALID') {
      // Invalid-token cleanup lives here so BOTH callers inherit it.
      await ctx.db.deleteDoc(`users/${plannerUid}/fcmTokens/${token}`);
      cleaned += 1;
    }
    // 'OTHER' (transient) errors are left alone — no send counted, not cleaned.
  }

  // Only stamp the guard once a push actually went out, so a run that found no
  // live token can still deliver on a later, genuine attempt.
  if (sent > 0) {
    await ctx.db.patchDoc(itemPath, {
      notifiedOutcome: actualOutcome,
      notifiedAt: new Date().toISOString(),
    });
  }

  return result(sent, cleaned, plannerUid, sent > 0 ? 'sent' : 'no-delivery');
}

// Payload carries ONLY what the recipient planner is already entitled to see:
// the item title (they created it) and the outcome verb. No note, no skip
// reason, nothing beyond their own item. `data` drives tap-routing.
function buildMessage(item, outcome, targetUid, itemId) {
  const title = (item.title || 'Your scheduled item').toString();
  const verb = outcome === 'done' ? 'marked done' : 'skipped';
  return {
    notification: {
      title: outcome === 'done' ? 'Task completed' : 'Task skipped',
      body: `${verb}: ${title}`,
    },
    data: {
      type: 'outcome',
      targetUid,
      itemId,
      outcome,
    },
  };
}

function result(sent, cleaned, recipientUid, reason) {
  return { sent, cleaned, recipientUid, reason };
}
