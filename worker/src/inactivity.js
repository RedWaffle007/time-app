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
export const INACTIVITY_MESSAGES = [
  'What deserves a spot on your schedule?',
  'A small plan now can clear your head.',
  'Ready to choose your next move?',
  'Put one useful thing on the clock.',
  'Your time is waiting for a direction.',
  'Pick one thing worth finishing today.',
  'A clear plan makes starting easier.',
  'What would make today feel well used?',
  'Give your next hour a purpose.',
  'Turn an intention into a time.',
  'One thoughtful plan is enough to begin.',
  'Make room for what matters next.',
  'What can future you thank you for?',
  'Choose a task. Choose its moment.',
  'A calm schedule starts with one item.',
  'Set a time for the thing on your mind.',
  'Your next win could use a time slot.',
  'Plan the next step, not the whole climb.',
  'What is worth protecting time for?',
  'Take a minute to shape the day.',
  'Make the next few hours intentional.',
  'One plan can turn waiting into progress.',
  'Put your priority where you can see it.',
  'What needs a real place in your day?',
  'Choose when, and make starting simpler.',
  'A little structure can create momentum.',
  'Schedule something your day needs.',
  'Decide what comes next on your terms.',
  'Give an important task a clear start.',
  'Make one promise to your future self.',
  'Your schedule has room for a next step.',
  'Name the task that deserves your focus.',
  'Plan something small and meaningful.',
  'What would lighten your mental load?',
  'Set one intention in motion.',
  'Choose a moment for what matters.',
  'A planned start beats a vague someday.',
  'Put the next useful action on your radar.',
  'What can you make easier by planning?',
  'Take back the next part of your day.',
  'Create one clear point to aim for.',
  'Your next task is easier with a when.',
  'Make space for one thing you value.',
  'Turn today’s priority into a plan.',
  'What is your next intentional hour?',
  'Give yourself a clear next checkpoint.',
  'A simple plan can restart momentum.',
  'Choose one task and give it a time.',
  'Set up the next version of your day.',
  'Ready when you are—plan one next step.',
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
