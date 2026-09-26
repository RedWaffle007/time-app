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

const EVENTS = new Set(['created', 'decided', 'outcome', 'withdrawn', 'dismissed']);

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
  const item = await ctx.db.getDoc(itemPath);
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
  // whichever way the notification flows (see itemGrantPath).
  const grant = await ctx.db.getDoc(itemGrantPath(item, plannerUid, targetUid));
  if (!grant || grant.granted !== true) {
    return result(0, 0, recipientUid, 'no-active-grant');
  }

  // Recipient's registered device tokens.
  const tokens = await ctx.db.listDocIds(`users/${recipientUid}/fcmTokens`);
  if (tokens.length === 0) return result(0, 0, recipientUid, 'no-tokens');

  // Names are read HERE, from Firestore, never taken from the request: the
  // actor is whoever performed this event (the planner for created/withdrawn,
  // the target for decided/outcome). A missing profile degrades to 'Someone'.
  const actorUid = NOTIFIES_TARGET.has(event) ? plannerUid : targetUid;
  const actor = await ctx.db.getDoc(`users/${actorUid}`);
  const group = groupId ? await ctx.db.getDoc(`groups/${groupId}`) : null;
  const message = buildMessage(event, derived.subtype, item, targetUid, itemId, {
    actorName: actor && actor.name ? String(actor.name) : null,
    groupName: groupId ? (group && group.name ? String(group.name) : '') : null,
  });

  let sent = 0;
  let cleaned = 0;
  for (const token of tokens) {
    const res = await ctx.fcm.send(token, message);
    if (res.ok) {
      sent += 1;
    } else if (res.error === 'UNREGISTERED' || res.error === 'INVALID') {
      // Invalid-token cleanup lives here so BOTH callers inherit it.
      await ctx.db.deleteDoc(`users/${recipientUid}/fcmTokens/${token}`);
      cleaned += 1;
    }
    // 'OTHER' (transient) errors are left alone — no send counted, not cleaned.
  }

  // Only stamp this event's guard once a push actually went out, so a run that
  // found no live token can still deliver on a later, genuine attempt.
  if (sent > 0) {
    await ctx.db.patchDoc(itemPath, {
      [derived.field]: derived.value,
      notifiedAt: new Date().toISOString(),
    });
  }

  return result(sent, cleaned, recipientUid, sent > 0 ? 'sent' : 'no-delivery');
}

// The grant that authorizes pushes about [item]. EMERGENCY permission is
// always the per-person friendship emergency grant — also for a group
// emergency plan, whose groupId is only a label (there is no group-level
// emergency grant; 2026-09-26). Otherwise group plans use the group's
// plannerGrants and friendship plans (empty groupId) the sorted-pair
// friendship subtree.
export function itemGrantPath(item, plannerUid, targetUid) {
  const grantId = `${plannerUid}_${targetUid}`;
  const pairId = [plannerUid, targetUid].sort().join('_');
  if (item.tier === 'emergency') {
    return `friendships/${pairId}/emergencyGrants/${grantId}`;
  }
  return item.groupId
    ? `groups/${item.groupId}/plannerGrants/${grantId}`
    : `friendships/${pairId}/plannerGrants/${grantId}`;
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
export const ACTIVITY_CHANNEL_ID = 'planner_activity';

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
  // "Emergency" leads every title about an emergency item (item 14), then
  // "group" for a group plan: "Emergency group task completed".
  const emergency = item.tier === 'emergency';
  const noun = (word) => {
    const phrase = `${emergency ? 'emergency ' : ''}${isGroup ? 'group ' : ''}${word}`;
    return phrase[0].toUpperCase() + phrase.slice(1);
  };
  const task = noun('task');
  const plan = noun('plan');

  let notification;
  switch (event) {
    case 'created':
      notification = {
        title: `New ${noun('plan').toLowerCase()} for you`,
        body: `${who} planned ${title} for you${inGroup}`,
      };
      break;
    case 'withdrawn':
      notification = {
        title: `${plan} withdrawn`,
        body: `${who} withdrew: ${title}${inGroup}`,
      };
      break;
    case 'decided':
      notification = subtype === 'approved'
        ? { title: `${plan} approved`, body: `${who} approved: ${title}${inGroup}` }
        : { title: `${plan} rejected`, body: `${who} rejected: ${title}${inGroup}` };
      break;
    case 'dismissed':
      notification = {
        title: `${noun('alarm')} dismissed`,
        body: `${who} dismissed the alarm for ${title}${inGroup}`,
      };
      break;
    case 'outcome': {
      const timing = outcomeTiming(subtype, item);
      if (subtype === 'done') {
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
  const isRemoteAlarm = event === 'created'
    && item.status === 'approved'
    && item.tier === 'emergency';
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
      },
    };
  }

  // HIGH priority: these are user-visible, and normal priority is batched
  // under Doze — a planner learning of a Done minutes late defeats the push.
  return {
    notification,
    data,
    android: {
      priority: 'high',
      notification: { channel_id: ACTIVITY_CHANNEL_ID },
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
//   planningRequest  requester (fromUid) recipient (toUid)      [#4/#5]
//   planningApprove  approver (toUid)   original requester (fromUid)
//
// The two planning events (a request for permission to PLAN, and its approval)
// ride the SAME wire shape and the SAME two directions as the friend events;
// they carry an extra `kind` (`normal`/`emergency`) that only changes the copy.
//
// The actor's display name is read from Firestore, never trusted from the
// caller, so the push body cannot be spoofed. Authorization (that the caller is
// the actor, and that the request/friendship/grant actually exists) is enforced
// by the transport shell BEFORE this runs — see index.js handleFriendEvent.
export const FRIEND_EVENTS = new Set([
  'friendRequest', 'friendAccept', 'planningRequest', 'planningApprove',
  'planRequested', 'groupJoinApproved',
]);

// Events whose recipient is the `toUid` (the other two notify the `fromUid`).
const NOTIFIES_TO_UID = new Set([
  'friendRequest', 'planningRequest', 'planRequested', 'groupJoinApproved',
]);

export async function sendFriendNotification(
  ctx,
  { event, fromUid, toUid, kind, planRequestId, groupId },
) {
  if (!FRIEND_EVENTS.has(event) || !fromUid || !toUid || fromUid === toUid) {
    return result(0, 0, null, 'bad-args');
  }

  const recipientUid = NOTIFIES_TO_UID.has(event) ? toUid : fromUid;
  const actorUid = NOTIFIES_TO_UID.has(event) ? fromUid : toUid;

  // Item 23 batches use deterministic request ids, so a client retry must not
  // ring the same friend twice. The request is durable; stamp it only after at
  // least one device accepted the push, matching item-event dedupe semantics.
  let planRequestPath = null;
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
    await ctx.db.patchDoc(planRequestPath, {
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
  const emergency = kind === 'emergency';
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
    case 'planningRequest':
      notification = emergency
        ? {
            title: 'Emergency planning request',
            body: `${who} wants to set emergency alarms for you`,
          }
        : {
            title: 'Planning request',
            body: `${who} wants to plan for you`,
          };
      break;
    case 'planningApprove':
      notification = emergency
        ? {
            title: 'Emergency planning approved',
            body: `${who} let you set emergency alarms for them`,
          }
        : {
            title: 'Planning approved',
            body: `${who} let you plan for them`,
          };
      break;
    case 'planRequested':
      notification = {
        title: 'Plan requested',
        body: `${who} asked you to plan something for them`,
      };
      break;
    case 'groupJoinApproved': {
      const name = groupInfo.groupName || 'the group';
      // A code request was asked for; a friend invitation was not, so it
      // reads as being added rather than approved.
      notification = groupInfo.joinSource === 'friend'
        ? { title: 'Added to a group', body: `You're now a member of ${name}` }
        : {
            title: 'Group join approved',
            body: `Your request to join ${name} was approved`,
          };
      break;
    }
  }

  return {
    notification,
    android: {
      priority: 'high',
      notification: { channel_id: ACTIVITY_CHANNEL_ID },
    },
    data: {
      type: event,
      event,
      fromUid,
      toUid,
      ...(kind ? { kind } : {}),
      ...(planRequestId ? { planRequestId } : {}),
      ...(event === 'groupJoinApproved' && groupInfo.groupId
        ? { groupId: groupInfo.groupId }
        : {}),
    },
  };
}
