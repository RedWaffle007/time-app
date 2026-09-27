// Durable six-hour inactivity notification policy. Transport-independent like
// notify.js: tests and a future server runtime can provide the same small ctx.

export const INACTIVITY_DELAY_MS = 6 * 60 * 60 * 1000;
const LEASE_MS = 5 * 60 * 1000;

// Each user costs ~7-8 Firestore/FCM subrequests; Cloudflare's free plan
// allows 50 per invocation, and exceeding it throws mid-run. Users beyond this
// cap stay due and are taken by the next 5-minute run (soonest-due first).
export const MAX_INACTIVITY_USERS_PER_RUN = 5;

// The app's own nudge channel — deliberately NOT the planner-activity channel,
// so a user can mute nudges without muting their people. Keep in step with
// `kNudgeChannelId` in foreground_push_presenter.dart.
export const NUDGE_CHANNEL_ID = 'app_nudges';

// Kept short so the notification is useful at a glance. The cursor advances
// only after at least one device receives the push; modulo wrap means no copy
// repeats until all fifty have been delivered in order.
//
// Rewritten 2026-09-27 to be about THIS app — friends setting alarms for each
// other, Request, voice alarms, groups, Stats — not generic productivity copy.
// Every line must be true for any user (no friends, no group, any hour of the
// day), so none assumes a friend is waiting, names a time of day, or threatens
// a streak (plan-less days never break one — the humane rule, item 24b).
export const INACTIVITY_MESSAGES = [
  'Set an alarm for a friend and help them show up today.',
  'Tap Request to ask a friend to set your next alarm.',
  'A friend’s voice beats any ringtone. Send a voice alarm.',
  'What should your mates remember today? Set it for them.',
  'Name a task and a time. Let a friend set the alarm.',
  'Plan one thing for yourself and let it ring.',
  'Record a short pep talk as a friend’s alarm.',
  'In a group? Set one alarm for everyone at once.',
  'Mates always remember. Set a reminder for one of yours.',
  'Know someone with a big day? Set them a reminder.',
  'Accountability works better in pairs. Plan with a friend.',
  'A reminder from a friend is hard to ignore.',
  'Check your Stats to see how your week is going.',
  'Send a friend a voice alarm that makes them smile.',
  'One alarm from you is one thing a friend won’t forget.',
  'Need a push? Let a friend be the one who reminds you.',
  'Plan your next task. Done or Skip, it’s your call.',
  'Sent a voice note before? Reuse it from your library.',
  'Water, stretch, call home: set a friend a kind reminder.',
  'Be the mate who remembers. Set an alarm for someone.',
  'Got a goal? Let a friend hold you to it.',
  'Planning is better with mates. Invite a friend.',
  'Start a group and plan the next session together.',
  'Your next alarm could be in a friend’s voice. Ask them.',
  'Pick a time, add a task, press Send. That’s it.',
  'Help a friend keep a promise. Set their reminder.',
  'A plan with a time rings. A plan in your head doesn’t.',
  'What do you want a mate to remind you about?',
  'Send encouragement that rings at the right minute.',
  'Set a study, gym or meds reminder for someone you love.',
  'Plan something small for yourself and check it off.',
  'Your friends can set alarms for you. Ask one.',
  'Surprise a friend with a voice alarm.',
  'Request a plan: pick a friend, a time and a task.',
  'Showing up is easier when someone is counting on you.',
  'Set a reminder for a friend before they forget.',
  'In a group? Your shared streak starts with one plan.',
  'Answer your alarms and watch your streak grow.',
  'Plan for a friend. Your name is on the alarm.',
  'Turn “I’ll do it later” into an alarm with a time.',
  'A five-second voice note can make someone’s day.',
  'A voice alarm repeats itself, so you only say it once.',
  'Who could use a nudge today? Set them a reminder.',
  'Let someone you trust plan your next step.',
  'Checkmate works best with friends. Add one now.',
  'Your follow-through lives in Stats. Take a look.',
  'Two minutes of planning beats an hour of drifting.',
  'Remind a friend of something that matters to them.',
  'A good friend remembers. A great one sets the alarm.',
  'Ready when you are. Plan one thing with a mate.',
];

export async function sendDueInactivityNotifications(ctx, now = new Date(), {
  maxUsers = MAX_INACTIVITY_USERS_PER_RUN,
} = {}) {
  const due = await ctx.db.listDueInactivityStates(now, maxUsers * 4);
  const summary = {
    considered: due.length, claimed: 0, sent: 0, cleaned: 0, failed: 0,
  };

  for (const row of due) {
    if (summary.claimed + summary.failed >= maxUsers) break;
    // One user's transient failure must not abort everyone after them in the
    // run (the old loop threw out of the whole pass). Their lease expires and
    // they are retried on a later run.
    try {
      await processInactivityRow(ctx, row, now, summary);
    } catch (error) {
      summary.failed += 1;
      console.log(JSON.stringify({
        event: 'inactivity-user-failed',
        detail: String(error && error.message),
      }));
    }
  }

  return summary;
}

async function processInactivityRow(ctx, row, now, summary) {
  const uid = row.id;
  const state = row.data || {};
  if (!uid || state.uid !== uid || !row.updateTime) return;

  const leaseUntil = parseDate(state.leaseUntil);
  if (leaseUntil && leaseUntil > now) return;

  const lastActivity = parseDate(state.lastActivityAt);
  if (!lastActivity) return;
  const genuinelyDueAt = new Date(lastActivity.getTime() + INACTIVITY_DELAY_MS);
  if (genuinelyDueAt > now) {
    // Repairs a stale due time without claiming or sending.
    await ctx.db.patchDocIfUnchanged(
      `inactivityStates/${uid}`,
      { nextNotificationAt: genuinelyDueAt },
      row.updateTime,
    );
    return;
  }

  const claimed = await ctx.db.patchDocIfUnchanged(
    `inactivityStates/${uid}`,
    { leaseUntil: new Date(now.getTime() + LEASE_MS) },
    row.updateTime,
  );
  if (!claimed) return;
  summary.claimed += 1;

  // Re-read after claiming. An app interaction that raced the claim updates
  // lastActivityAt/nextNotificationAt; in that case it wins and no push goes.
  const current = await ctx.db.getDoc(`inactivityStates/${uid}`);
  const currentActivity = parseDate(current?.lastActivityAt);
  if (!current || !currentActivity ||
      currentActivity.getTime() + INACTIVITY_DELAY_MS > now.getTime()) {
    await ctx.db.patchDoc(`inactivityStates/${uid}`, { leaseUntil: null });
    return;
  }

  const rawIndex = Number.isInteger(current.sequenceIndex)
    ? current.sequenceIndex
    : 0;
  const index = ((rawIndex % INACTIVITY_MESSAGES.length) +
    INACTIVITY_MESSAGES.length) % INACTIVITY_MESSAGES.length;
  const tokens = await ctx.db.listDocIds(`users/${uid}/fcmTokens`);
  let delivered = 0;
  let cleaned = 0;
  for (const token of tokens) {
    const result = await ctx.fcm.send(token, buildInactivityMessage(index));
    if (result.ok) {
      delivered += 1;
    } else if (result.error === 'UNREGISTERED' || result.error === 'INVALID') {
      await ctx.db.deleteDoc(`users/${uid}/fcmTokens/${token}`);
      cleaned += 1;
    }
  }

  summary.sent += delivered;
  summary.cleaned += cleaned;
  const deliveredAt = new Date(now);
  await ctx.db.patchDoc(`inactivityStates/${uid}`, {
    leaseUntil: null,
    nextNotificationAt: new Date(now.getTime() + INACTIVITY_DELAY_MS),
    ...(delivered > 0 ? {
      sequenceIndex: (index + 1) % INACTIVITY_MESSAGES.length,
      lastNotifiedAt: deliveredAt,
    } : {}),
  });

  // If opening/tapping the app raced the network sends, its newer activity
  // must remain the timer anchor. Repair after finalization so the Worker's
  // `now + 6h` write cannot shorten that fresh six-hour window.
  const afterDelivery = await ctx.db.getDoc(`inactivityStates/${uid}`);
  const activityAfterDelivery = parseDate(afterDelivery?.lastActivityAt);
  if (activityAfterDelivery && activityAfterDelivery > now) {
    await ctx.db.patchDoc(`inactivityStates/${uid}`, {
      nextNotificationAt: new Date(
        activityAfterDelivery.getTime() + INACTIVITY_DELAY_MS,
      ),
    });
  }
}

export function buildInactivityMessage(index) {
  return {
    notification: {
      title: 'Make time for what matters',
      body: INACTIVITY_MESSAGES[index],
    },
    data: { type: 'inactivity', event: 'inactivity' },
    // HIGH: a normal-priority message can be held for hours under Doze, so a
    // "six-hour" nudge would arrive whenever the phone next woke.
    android: {
      priority: 'high',
      notification: { channel_id: NUDGE_CHANNEL_ID },
    },
  };
}

function parseDate(value) {
  if (typeof value !== 'string') return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}
