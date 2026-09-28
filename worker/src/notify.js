// notify.js — the portable, transport-agnostic notification policy.
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
// args = { event, targetUid, itemId }.
//
// ONE endpoint, FOUR events — but they are NOT symmetric (see DECISIONS.md
// "Group A"). Two are planner-triggered and notify the TARGET; two are
// target-triggered and notify the PLANNER (creator):
//
//   event       triggered by   notifies   sub-type (re-read from Firestore)
//   ---------   ------------   --------   ---------------------------------
//   created     planner        target     —
//   withdrawn   planner        target     —
//   decided     target         planner    approved | rejected  (item.status)
//   outcome     target         planner    done | skipped       (outcome.result)
//   dismissed   target         planner    —  (requires item.alarm.dismissedAt)
//
// `event` says WHICH transition this push is for; it is NOT trusted as the state.
// The item is re-read and the sub-type is DERIVED from Firestore — the caller
// cannot assert an outcome/decision that didn't actually happen.

// THE one list of item events. index.js imports it for its request guard, so
// a new event can never again be accepted here but rejected at the door (the
// `unavailable` push was 400'd by a second, stale list until 2026-09-27).
import { recordAndBuildSummary, summaryListFor } from './group-summary.js';

export const ITEM_EVENTS = new Set([
  'created', 'decided', 'outcome', 'withdrawn', 'dismissed', 'voiceFallback',
  'unavailable',
]);
const EVENTS = ITEM_EVENTS;

// Which party each event notifies. The ACTOR is never the recipient: for a
// planner-triggered event the recipient is the target, and vice versa — and the
// self-planned guard below removes the one case where they'd coincide.
const NOTIFIES_TARGET = new Set(['created', 'withdrawn']);

/**
 * Resolve + send one notification. Fails CLOSED: if any lookup throws, it
 * propagates (the caller returns an error) and NO push goes out. A "nothing to
 * send" condition (already-notified, no active grant, state not yet written, no
 * recipient token) is returned as a normal result, not an error — do NOT retry.
 *
 * @returns {Promise<{sent:number, cleaned:number, recipientUid:(string|null), reason:string}>}
 */
export async function sendEventNotification(ctx, { event, targetUid, itemId }) {
  if (!targetUid || !itemId || !EVENTS.has(event)) {
    return result(0, 0, null, 'bad-args');
  }

  const itemPath = `scheduleItems/${targetUid}/items/${itemId}`;
  // With `updateTime` when the db supports it: the dedup slot is then CLAIMED
  // atomically before sending (see claimSlot), so near-simultaneous calls for
  // the same event (every dismiss path reports) push exactly once.
  const withMeta = ctx.db.getDocWithMeta
    ? await ctx.db.getDocWithMeta(itemPath)
    : null;
  const item = withMeta ? withMeta.data : await ctx.db.getDoc(itemPath);
  if (!item) return result(0, 0, null, 'item-not-found');

  const plannerUid = item.createdByUid;
  const groupId = item.groupId;
  if (!plannerUid || typeof groupId !== 'string') {
    return result(0, 0, null, 'item-missing-fields');
  }

  // A self-planned item (creator == target) has no second party — nobody to
  // notify, for ANY event.
  if (plannerUid === targetUid) return result(0, 0, null, 'self-planned');

  // Derive + VERIFY the sub-type from Firestore, and pick this event's OWN dedup
  // slot. Each event writes a distinct field, so one firing can never suppress
  // another on the same item.
  const derived = deriveEvent(event, item);
  if (!derived.ok) return result(0, 0, null, derived.reason);

  // Per-event duplicate / replay guard. Re-posts of an event already delivered
  // (killed-then-relaunched app, or a malicious re-post) are ignored.
  if (item[derived.field] === derived.value) {
    return result(0, 0, null, 'already-notified');
  }

  const recipientUid = NOTIFIES_TARGET.has(event) ? targetUid : plannerUid;

  // Active grant required in BOTH directions — a revoked grant means no push,
  // whichever way the notification flows (see hasActiveItemGrant). The
  // permission check and the recipient's tokens are read TOGETHER
  // (2026-09-27): independent reads, and the push lands sooner. Nothing is
  // sent before the permission check has passed.
  const [granted, tokens] = await Promise.all([
    hasActiveItemGrant(ctx.db, item, plannerUid, targetUid),
    ctx.db.listDocIds(`users/${recipientUid}/fcmTokens`),
  ]);
  if (!granted) return result(0, 0, recipientUid, 'no-active-grant');
  if (tokens.length === 0) return result(0, 0, recipientUid, 'no-tokens');

  // Claim this event's slot BEFORE sending. The read above and the stamp used
  // to be separate steps, so three reports of one dismissal arriving together
  // all saw "not yet notified" and all pushed (seen on device 2026-09-27).
  const claimed = await claimSlot(ctx.db, itemPath, derived, withMeta);
  if (!claimed) return result(0, 0, recipientUid, 'already-notified');

  // Names are read HERE, from Firestore, never taken from the request: the
  // actor is whoever performed this event (the planner for created/withdrawn,
  // the target for decided/outcome). A missing profile degrades to 'Someone'.
  const actorUid = NOTIFIES_TARGET.has(event) ? plannerUid : targetUid;
  // A group plan's ring result and missed-popup answers reach the planner as
  // LIVE lists, not one push per member (2026-09-28, group-summary.js).
  const summaryList = summaryListFor(event, derived.subtype, item);
  let message;
  if (summaryList) {
    message = await recordAndBuildSummary(ctx, item, targetUid, summaryList);
    if (!message) return result(0, 0, recipientUid, 'nothing-to-send');
  } else {
    const [actor, group] = await Promise.all([
      ctx.db.getDoc(`users/${actorUid}`),
      groupId ? ctx.db.getDoc(`groups/${groupId}`) : Promise.resolve(null),
    ]);
    message = buildMessage(event, derived.subtype, item, targetUid, itemId, {
      actorName: actor && actor.name ? String(actor.name) : null,
      groupName: groupId ? (group && group.name ? String(group.name) : '') : null,
    });
  }

  // Every device at once (2026-09-27) rather than one after another.
  let sent = 0;
  let cleaned = 0;
  await Promise.all(tokens.map(async (token) => {
    const res = await ctx.fcm.send(token, message);
    if (res.ok) {
      sent += 1;
    } else if (res.error === 'UNREGISTERED' || res.error === 'INVALID') {
      // Invalid-token cleanup lives here so BOTH callers inherit it.
      await ctx.db.deleteDoc(`users/${recipientUid}/fcmTokens/${token}`);
      cleaned += 1;
    }
    // 'OTHER' (transient) errors are left alone — no send counted, not cleaned.
  }));

  // Keep the stamp only if a push actually went out, so a run that reached no
  // live token can still deliver on a later, genuine attempt.
  if (sent > 0) {
    await ctx.db.patchDoc(itemPath, {
      [derived.field]: derived.value,
      notifiedAt: new Date().toISOString(),
    });
  } else if (withMeta) {
    await ctx.db.patchDoc(itemPath, { [derived.field]: null });
  }

  return result(sent, cleaned, recipientUid, sent > 0 ? 'sent' : 'no-delivery');
}

// Atomically take this event's dedup slot. Compare-and-set on the item's
// `updateTime`: exactly one concurrent caller wins. A loser re-reads — if the
// slot is now taken it was a duplicate; if something else changed the item
// (an outcome, a timeline stamp) it retries with the fresh version. Without
// updateTime support (older test doubles) it falls back to send-then-stamp.
async function claimSlot(db, itemPath, derived, withMeta) {
  if (!withMeta || !db.patchDocIfUnchanged) return true;
  let updateTime = withMeta.updateTime;
  for (let attempt = 0; attempt < 3; attempt++) {
    const won = await db.patchDocIfUnchanged(
      itemPath,
      { [derived.field]: derived.value },
      updateTime,
    );
    if (won) return true;
    const fresh = await db.getDocWithMeta(itemPath);
    if (!fresh || fresh.data[derived.field] === derived.value) return false;
    updateTime = fresh.updateTime;
  }
  return false;
}

// Does the planner CURRENTLY hold permission over the target for [item]?
// Mirrors the create rule (Batch G items 2 + 3, 2026-09-27): a FRIEND may set
// an untagged plan, and fellow MEMBERS of the tagged group may set a group
// plan. No grant documents. Every item push, the lapse notices and the voice
// rescue ask this; a lost permission means no push, whichever way it flows.
export async function hasActiveItemGrant(db, item, plannerUid, targetUid) {
  if (item.groupId) {
    return bothInGroup(db, item.groupId, plannerUid, targetUid);
  }
  const pairId = [plannerUid, targetUid].sort().join('_');
  return Boolean(await db.getDoc(`friendships/${pairId}`));
}

export async function bothInGroup(db, groupId, a, b) {
  const group = await db.getDoc(`groups/${groupId}`);
  const members = group && Array.isArray(group.memberUids) ? group.memberUids : [];
  return members.includes(a) && members.includes(b);
}

// The group's admins: the creator always, plus `adminUids`, members only.
export function groupAdminUids(group) {
  if (!group) return [];
  const members = Array.isArray(group.memberUids) ? group.memberUids : [];
  const listed = Array.isArray(group.adminUids) ? group.adminUids : [];
  return [...new Set([group.ownerUid, ...listed])]
    .filter((uid) => typeof uid === 'string' && members.includes(uid));
}

// Verify the event against the item's ACTUAL Firestore state and return this
// event's dedup slot. `created` is the one event with no pre-existing state to
// check — it fires right after the doc is written — so its guard is a simple
// one-shot flag.
function deriveEvent(event, item) {
  switch (event) {
    case 'created':
      return { ok: true, subtype: null, field: 'notifiedCreated', value: true };
    case 'withdrawn':
      if (item.status !== 'withdrawn') return { ok: false, reason: 'not-withdrawn' };
      return { ok: true, subtype: null, field: 'notifiedWithdrawn', value: true };
    case 'decided': {
      const st = item.status;
      if (st !== 'approved' && st !== 'rejected') {
        return { ok: false, reason: 'not-decided' };
      }
      return { ok: true, subtype: st, field: 'notifiedDecided', value: st };
    }
    case 'outcome': {
      const r = item.outcome && item.outcome.result;
      if (r !== 'done' && r !== 'skipped') {
        return { ok: false, reason: 'outcome-not-recorded' };
      }
      return { ok: true, subtype: r, field: 'notifiedOutcome', value: r };
    }
    case 'voiceFallback':
      // Item 32c-2: the target's phone stamps `alarm.voiceFallbackAt` when a
      // voice-note alarm had to ring the normal ringtone.
      if (!item.voiceNote || !item.alarm || !item.alarm.voiceFallbackAt) {
        return { ok: false, reason: 'no-voice-fallback' };
      }
      return { ok: true, subtype: null, field: 'notifiedVoiceFallback', value: true };
    case 'unavailable':
      // Item 6 (2026-09-27): the alarm auto-stopped unanswered and the
      // target's device recorded the immutable `alarm.unavailableAt`.
      if (!item.alarm || !item.alarm.unavailableAt) {
        return { ok: false, reason: 'not-unavailable' };
      }
      return { ok: true, subtype: null, field: 'notifiedUnavailable', value: true };
    case 'dismissed':
      // The target's device records `alarm.dismissedAt` when the ringing alarm
      // is dismissed; no recorded dismissal, no push.
      if (!item.alarm || !item.alarm.dismissedAt) {
        return { ok: false, reason: 'not-dismissed' };
      }
      return { ok: true, subtype: null, field: 'notifiedDismissed', value: true };
    default:
      return { ok: false, reason: 'bad-args' };
  }
}

// The Android channel item/friend pushes post on, background AND foreground
// (the app shows foreground ones itself on the same id — keep them in step with
// `kPlannerActivityChannelId` in foreground_push_presenter.dart). Never the
// reminder channel: silencing someone else's activity must not silence alarms.
/**
 * A voice alarm someone else sent (2026-09-28): no Done/Skip. Dismissing it
 * while it rings means heard; the missed popup's Play / Already heard mean
 * heard late; 24 hours unanswered lapses it. Self-plans never carry a note.
 */
/**
 * The "Uh-Oh!" item events (2026-09-28): the alarm rang out unanswered, and a
 * Skip given on the missed popup (after it rang out). Everything else plays
 * the phone's normal tone.
 */
export function isNegativeItemEvent(event, subtype, item) {
  if (event === 'unavailable') return true;
  return event === 'outcome' && subtype === 'skipped'
    && Boolean(item && item.alarm && item.alarm.unavailableAt);
}

export function isVoiceAlarm(item) {
  return Boolean(item && item.voiceNote)
    && Boolean(item.createdByUid) && item.createdByUid !== item.targetUid;
}

export const ACTIVITY_CHANNEL_ID = 'planner_activity';

// Item 6 (2026-09-27): "{Y} was unavailable…" plays a cartoon "Uh-Oh!"
// (Breviceps, CC0, res/raw/uh_oh.mp3). A channel's sound is fixed when it is
// created, so it has its own channel — keep in step with
// `kPlannerUnavailableChannelId` in foreground_push_presenter.dart.
export const UNAVAILABLE_CHANNEL_ID = 'planner_unavailable';

// When the outcome was recorded relative to the plan, from Firestore state
// only. 'late' = a missed alarm was later answered Done; 'early' = the outcome
// timestamp precedes the scheduled instant. Unknown timestamps are 'onTime'.
export function outcomeTiming(subtype, item) {
  if (subtype === 'done' && item.alarm && item.alarm.unavailableAt) return 'late';
  const o = item.outcome || {};
  const at = Date.parse(subtype === 'done' ? o.completedAt : o.skippedAt);
  const due = Date.parse(item.scheduledInstantUtc);
  if (Number.isFinite(at) && Number.isFinite(due) && at < due) return 'early';
  return 'onTime';
}

// Payload carries ONLY what the recipient is already entitled to see: the item
// title (creator made it; target owns it), the actor's display name (the other
// party of this plan) and, for a group plan, the group's name (both are
// members). No note, no skip/reject reason. `data` drives tap-routing (see
// app.dart _handleTap) — `type` is kept for back-compat with the outcome-only
// payload; `event` is the discriminator going forward.
//
// `names.groupName` is null for a friendship plan and a string (possibly empty)
// for a group plan, so a group plan is labelled even if its name is missing.
export function buildMessage(event, subtype, item, targetUid, itemId, names = {}) {
  const title = (item.title || 'your scheduled item').toString();
  const who = names.actorName || 'Someone';
  const isGroup = typeof names.groupName === 'string';
  const inGroup = isGroup && names.groupName ? ` in ${names.groupName}` : '';
  // "group" for a group plan: "Group task completed". The "Emergency" label
  // is retired (F2, 2026-09-26): every alarm now rings directly, so there is
  // nothing left to single out — even on a legacy emergency-tier item.
  const noun = (word) => {
    const phrase = `${isGroup ? 'group ' : ''}${word}`;
    return phrase[0].toUpperCase() + phrase.slice(1);
  };
  const task = noun('task');
  const plan = noun('plan');

  let notification;
  switch (event) {
    case 'created':
      // An approved (F2: every new) alarm is announced as an alarm; a legacy
      // pending plan from an older client is still a plan.
      notification = item.status === 'approved'
        ? {
            title: `New ${noun('alarm').toLowerCase()} for you`,
            // A voice alarm has no task name (F4): the recording is the message.
            body: item.voiceNote
              ? `${who} sent you a voice alarm${inGroup}`
              : `${who} set ${title} for you${inGroup}`,
          }
        : {
            title: `New ${noun('plan').toLowerCase()} for you`,
            body: `${who} planned ${title} for you${inGroup}`,
          };
      break;
    case 'withdrawn':
      // F2: the planner's Cancel.
      notification = {
        title: `${noun('alarm')} cancelled`,
        body: `${who} cancelled: ${title}${inGroup}`,
      };
      break;
    case 'decided':
      notification = subtype === 'approved'
        ? { title: `${plan} approved`, body: `${who} approved: ${title}${inGroup}` }
        : { title: `${plan} rejected`, body: `${who} rejected: ${title}${inGroup}` };
      break;
    case 'voiceFallback':
      notification = {
        title: "Voice note didn't play",
        body: `${who}'s alarm for ${title}${inGroup} rang with the normal ringtone. Your voice note couldn't play.`,
      };
      break;
    case 'unavailable':
      // Plays the "Uh-Oh!" tone: its own channel (UNAVAILABLE_CHANNEL_ID).
      notification = isVoiceAlarm(item)
        ? {
            title: `${who} missed your voice note`,
            body: `${who} missed your voice note${inGroup}.`,
          }
        : {
            title: `${who} was unavailable`,
            body: `${who} was unavailable to dismiss the task: ${title} you planned for them${inGroup}.`,
          };
      break;
    case 'dismissed':
      // A voice note has no Done/Skip (2026-09-28): dismissing it while it
      // rang IS hearing it.
      notification = isVoiceAlarm(item)
        ? {
            title: 'Voice note heard',
            body: `${who} heard your voice note${inGroup}.`,
          }
        : {
            title: `${noun('alarm')} dismissed`,
            body: `${who} dismissed the alarm for ${title}${inGroup}`,
          };
      break;
    case 'outcome': {
      const timing = outcomeTiming(subtype, item);
      if (subtype === 'done' && isVoiceAlarm(item)) {
        // Play / Already heard on the missed popup (or the card): heard late.
        notification = timing === 'late'
          ? {
              title: 'Voice note heard late',
              body: `${who} heard your voice note late${inGroup}.`,
            }
          : {
              title: 'Voice note heard',
              body: `${who} heard your voice note${inGroup}.`,
            };
      } else if (subtype === 'done') {
        notification = timing === 'late'
          ? {
              title: `${task} completed late`,
              body: `${who} completed the task after a missed alarm: ${title}${inGroup}`,
            }
          : timing === 'early'
            ? {
                title: `${task} completed early`,
                body: `${who} completed Task: ${title} before time${inGroup}`,
              }
            : {
                title: `${task} completed`,
                body: `${who} completed the task: ${title}${inGroup}`,
              };
      } else {
        notification = timing === 'early'
          ? {
              title: `${task} skipped early`,
              body: `${who} skipped Task: ${title} before time${inGroup}`,
            }
          : {
              title: `${task} skipped`,
              body: `${who} skipped task: ${title}${inGroup}`,
            };
      }
      break;
    }
  }

  const data = {
    type: event === 'outcome' ? 'outcome' : event,
    event,
    targetUid,
    itemId,
    ...(subtype ? { subtype } : {}),
  };

  // An emergency item is born approved on somebody else's device. A normal
  // notification payload would be drawn by Android while the app is killed,
  // but Dart would never run and therefore could not arm the due-time alarm.
  // Send this one as HIGH-priority data so the registered background handler
  // runs and installs the local alarm. Every data value must be a string for
  // FCM HTTP v1.
  // F2: EVERY approved new alarm arms the target's phone from this data
  // message (it used to be emergency-only), so a killed app still rings.
  const isRemoteAlarm = event === 'created' && item.status === 'approved';
  if (isRemoteAlarm) {
    return {
      android: { priority: 'high' },
      data: {
        ...data,
        command: 'scheduleReminder',
        fireAtUtc: String(item.scheduledInstantUtc || ''),
        title,
        body: item.note
          ? String(item.note)
          : 'Tap to mark it done or skip.',
        pushTitle: notification.title,
        pushBody: notification.body,
        // A voice-note emergency (item 32c-2): the killed-app handler arms the
        // alarm with the note and fetches it at once. Strings, as FCM needs.
        ...(item.voiceNote && typeof item.voiceNote.sha256 === 'string'
          && item.createdByUid !== targetUid
          ? {
              voiceSha256: item.voiceNote.sha256,
              voiceSizeBytes: String(item.voiceNote.sizeBytes || ''),
            }
          : {}),
      },
    };
  }

  // HIGH priority: these are user-visible, and normal priority is batched
  // under Doze — a planner learning of a Done minutes late defeats the push.
  const uhOh = isNegativeItemEvent(event, subtype, item);
  return {
    notification,
    data: uhOh ? { ...data, uhOh: 'true' } : data,
    android: {
      priority: 'high',
      notification: {
        channel_id: uhOh ? UNAVAILABLE_CHANNEL_ID : ACTIVITY_CHANNEL_ID,
      },
    },
  };
}

function result(sent, cleaned, recipientUid, reason) {
  return { sent, cleaned, recipientUid, reason };
}

// ---------------------------------------------------------------------------
// Friend-graph notifications. A SEPARATE family from the item events above:
// different body shape ({fromUid, toUid}, no itemId), different recipient rule,
// and no dedup slot. Dedup is unnecessary because the friendRequests row is
// DELETED on decline/withdraw, so a re-request is a genuinely new event; a rare
// double-fire from the client's self-heal retry is harmless.
//
//   event            triggered by       notifies
//   ---------------  ----------------   -----------------------------
//   friendRequest    sender (fromUid)   recipient (toUid)
//   friendAccept     accepter (toUid)   original sender (fromUid)
//
// (The planningRequest / planningApprove events were retired with the
// planning-permission requests on 2026-09-27: friendship is the permission.)
//
// The actor's display name is read from Firestore, never trusted from the
// caller, so the push body cannot be spoofed. Authorization (that the caller is
// the actor, and that the request/friendship/grant actually exists) is enforced
// by the transport shell BEFORE this runs — see index.js handleFriendEvent.
export const FRIEND_EVENTS = new Set([
  'friendRequest', 'friendAccept', 'planRequested', 'groupJoinApproved',
  'groupJoinRequested', 'planRequestDeclined',
]);

// planRequestDeclined (2026-09-28): the friend asked (toUid) declined the
// requester's (fromUid) plan request — a negative event, "Uh-Oh!".
const UH_OH_FRIEND_EVENTS = new Set(['planRequestDeclined']);

// Events whose recipient is the `toUid` (the other two notify the `fromUid`).
const NOTIFIES_TO_UID = new Set([
  'friendRequest', 'planRequested', 'groupJoinApproved',
]);

export async function sendFriendNotification(
  ctx,
  { event, fromUid, toUid, kind, planRequestId, groupId },
) {
  // A code request is the candidate asking for THEMSELVES, so it is the one
  // event where the two parties may be the same person.
  if (event === 'groupJoinRequested' && fromUid && toUid) {
    return sendGroupJoinRequestNotification(ctx, { fromUid, toUid, groupId });
  }
  if (!FRIEND_EVENTS.has(event) || !fromUid || !toUid || fromUid === toUid) {
    return result(0, 0, null, 'bad-args');
  }

  const recipientUid = NOTIFIES_TO_UID.has(event) ? toUid : fromUid;
  const actorUid = NOTIFIES_TO_UID.has(event) ? fromUid : toUid;

  // Item 23 batches use deterministic request ids, so a client retry must not
  // ring the same friend twice. The request is durable; stamp it only after at
  // least one device accepted the push, matching item-event dedupe semantics.
  let planRequestPath = null;
  let declinedTask = null;
  if (event === 'planRequestDeclined') {
    if (!planRequestId) return result(0, 0, recipientUid, 'bad-args');
    planRequestPath = `planRequests/${planRequestId}`;
    const request = await ctx.db.getDoc(planRequestPath);
    if (!request) return result(0, 0, recipientUid, 'request-not-found');
    if (request.status !== 'declined' || request.requesterUid !== fromUid
      || request.plannerUid !== toUid) {
      return result(0, 0, recipientUid, 'not-declined');
    }
    if (request.notifiedDeclined === true) {
      return result(0, 0, recipientUid, 'already-notified');
    }
    declinedTask = request.title ? String(request.title) : null;
  }
  if (event === 'planRequested') {
    if (!planRequestId) return result(0, 0, recipientUid, 'bad-args');
    planRequestPath = `planRequests/${planRequestId}`;
    const request = await ctx.db.getDoc(planRequestPath);
    if (!request) return result(0, 0, recipientUid, 'request-not-found');
    if (request.notifiedRequested === true) {
      return result(0, 0, recipientUid, 'already-notified');
    }
  }

  // groupJoinApproved (toUid = the admitted candidate): only for a request
  // that Firestore says is approved AND a candidate now on the roster, and
  // at most once per request — the stamp lives on the request itself.
  let joinRequestPath = null;
  let group = null;
  let joinSource = null;
  if (event === 'groupJoinApproved') {
    if (!groupId) return result(0, 0, recipientUid, 'bad-args');
    joinRequestPath = `groups/${groupId}/joinRequests/${toUid}`;
    const request = await ctx.db.getDoc(joinRequestPath);
    if (!request) return result(0, 0, recipientUid, 'request-not-found');
    if (request.status !== 'approved') {
      return result(0, 0, recipientUid, 'not-approved');
    }
    group = await ctx.db.getDoc(`groups/${groupId}`);
    const members = group && Array.isArray(group.memberUids)
      ? group.memberUids
      : [];
    if (!members.includes(toUid)) return result(0, 0, recipientUid, 'not-member');
    if (request.notifiedApproved === true) {
      return result(0, 0, recipientUid, 'already-notified');
    }
    joinSource = request.source;
  }

  const actor = await ctx.db.getDoc(`users/${actorUid}`);
  const who = actor && actor.name ? String(actor.name) : 'Someone';

  const tokens = await ctx.db.listDocIds(`users/${recipientUid}/fcmTokens`);
  if (tokens.length === 0) return result(0, 0, recipientUid, 'no-tokens');

  const message = buildFriendMessage(
    event, who, fromUid, toUid, kind, planRequestId,
    {
      groupId,
      groupName: group && group.name ? String(group.name) : '',
      joinSource,
      task: declinedTask,
    },
  );

  let sent = 0;
  let cleaned = 0;
  for (const token of tokens) {
    const res = await ctx.fcm.send(token, message);
    if (res.ok) {
      sent += 1;
    } else if (res.error === 'UNREGISTERED' || res.error === 'INVALID') {
      await ctx.db.deleteDoc(`users/${recipientUid}/fcmTokens/${token}`);
      cleaned += 1;
    }
  }

  if (sent > 0 && joinRequestPath) {
    await ctx.db.patchDoc(joinRequestPath, {
      notifiedApproved: true,
      notifiedApprovedAt: new Date().toISOString(),
    });
  }

  if (sent > 0 && planRequestPath) {
    await ctx.db.patchDoc(planRequestPath, event === 'planRequestDeclined'
      ? { notifiedDeclined: true, notifiedDeclinedAt: new Date().toISOString() }
      : {
          notifiedRequested: true,
          notifiedRequestedAt: new Date().toISOString(),
        });
  }

  return result(sent, cleaned, recipientUid, sent > 0 ? 'sent' : 'no-delivery');
}

// Carries only the actor's display name — a fact the recipient is entitled to
// (they are about to see it in the request / friends list anyway). `data` drives
// tap-routing (notification_routing.dart).
function buildFriendMessage(
  event, who, fromUid, toUid, kind, planRequestId, groupInfo = {},
) {
  let notification;
  switch (event) {
    case 'friendRequest':
      notification = {
        title: 'New friend request',
        body: `${who} sent you a friend request`,
      };
      break;
    case 'friendAccept':
      notification = {
        title: 'Friend request accepted',
        body: `${who} accepted your friend request`,
      };
      break;
    case 'planRequested':
      // Item 5 (2026-09-27): the redesigned wording, shared with reminders.
      notification = {
        title: 'Plan request',
        body: `${who} has requested you to plan for them. Click to view details.`,
      };
      break;
    case 'planRequestDeclined':
      notification = {
        title: 'Plan request declined',
        body: groupInfo.task
          ? `${who} declined your plan request for "${groupInfo.task}".`
          : `${who} declined your plan request.`,
      };
      break;
    case 'groupJoinApproved': {
      const name = groupInfo.groupName || 'the group';
      // A code request was asked for; a friend invitation was not, so it
      // reads as being added rather than approved.
      notification = groupInfo.joinSource === 'friend'
          || groupInfo.joinSource === 'admin'
        ? { title: 'Added to a group', body: `You're now a member of ${name}` }
        : {
            title: 'Group join approved',
            body: `Your request to join ${name} was approved`,
          };
      break;
    }
  }

  const uhOh = UH_OH_FRIEND_EVENTS.has(event);
  return {
    notification,
    android: {
      priority: 'high',
      notification: {
        channel_id: uhOh ? UNAVAILABLE_CHANNEL_ID : ACTIVITY_CHANNEL_ID,
      },
    },
    data: {
      type: event,
      event,
      fromUid,
      toUid,
      ...(uhOh ? { uhOh: 'true' } : {}),
      ...(kind ? { kind } : {}),
      ...(planRequestId ? { planRequestId } : {}),
      ...(event === 'groupJoinApproved' && groupInfo.groupId
        ? { groupId: groupInfo.groupId }
        : {}),
    },
  };
}

// groupJoinRequested (item 3, 2026-09-27): a join request is waiting, so EVERY
// admin is told — any one of them may decide. `toUid` is the candidate;
// `fromUid` asked (the candidate for a code request, the inviting member for
// a friend invitation). Only for a request Firestore says is still pending and
// was made by `fromUid`; stamped once delivered so a retry cannot re-ring.
export async function sendGroupJoinRequestNotification(ctx, { fromUid, toUid, groupId }) {
  if (!groupId || groupId.includes('/')) return result(0, 0, null, 'bad-args');
  const requestPath = `groups/${groupId}/joinRequests/${toUid}`;
  const request = await ctx.db.getDoc(requestPath);
  if (!request) return result(0, 0, null, 'request-not-found');
  if (request.status !== 'pending' || request.requestedByUid !== fromUid) {
    return result(0, 0, null, 'not-pending');
  }
  if (request.notifiedRequested === true) {
    return result(0, 0, null, 'already-notified');
  }
  const group = await ctx.db.getDoc(`groups/${groupId}`);
  const admins = groupAdminUids(group).filter((uid) => uid !== fromUid);
  if (admins.length === 0) return result(0, 0, null, 'no-admins');

  const groupName = group && group.name ? String(group.name) : 'your group';
  const candidateName = request.candidateName
    ? String(request.candidateName)
    : 'Someone';
  let body = `${candidateName} wants to join ${groupName}`;
  if (fromUid !== toUid) {
    const inviter = await ctx.db.getDoc(`users/${fromUid}`);
    const who = inviter && inviter.name ? String(inviter.name) : 'A member';
    body = `${who} invited ${candidateName} to join ${groupName}`;
  }
  const message = {
    notification: { title: 'Join request', body },
    android: {
      priority: 'high',
      notification: { channel_id: ACTIVITY_CHANNEL_ID },
    },
    data: {
      type: 'groupJoinRequested',
      event: 'groupJoinRequested',
      fromUid,
      toUid,
      groupId,
    },
  };

  let sent = 0;
  let cleaned = 0;
  for (const admin of admins) {
    const tokens = await ctx.db.listDocIds(`users/${admin}/fcmTokens`);
    for (const token of tokens) {
      const res = await ctx.fcm.send(token, message);
      if (res.ok) {
        sent += 1;
      } else if (res.error === 'UNREGISTERED' || res.error === 'INVALID') {
        await ctx.db.deleteDoc(`users/${admin}/fcmTokens/${token}`);
        cleaned += 1;
      }
    }
  }
  if (sent > 0) {
    await ctx.db.patchDoc(requestPath, {
      notifiedRequested: true,
      notifiedRequestedAt: new Date().toISOString(),
    });
  }
  return result(sent, cleaned, null, sent > 0 ? 'sent' : 'no-delivery');
}
