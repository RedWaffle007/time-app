import assert from 'node:assert/strict';
import test from 'node:test';

import {
  planRequestBody,
  reminderTimes,
  sendPlanRequestReminders,
  slotsDue,
} from '../src/plan-request-reminders.js';
import { sendFriendNotification } from '../src/notify.js';

// Batch G item 5 (2026-09-27): reminders at 50% and 75% of the window until
// the friend actually creates the plan.

const at = (hhmm) => new Date(`2030-10-04T${hhmm}:00Z`);
const SENT = at('16:00');
const DUE = at('18:00');

test('4 PM → 6 PM reminds at 5:00 and 5:30', () => {
  assert.deepEqual(reminderTimes(SENT, DUE).map((d) => d.toISOString()), [
    at('17:00').toISOString(),
    at('17:30').toISOString(),
  ]);
});

test('a 10-minute window reminds at +5 and +7.5 minutes', () => {
  const [a, b] = reminderTimes(at('16:00'), at('16:10'));
  assert.equal(a.toISOString(), '2030-10-04T16:05:00.000Z');
  assert.equal(b.toISOString(), '2030-10-04T16:07:30.000Z');
});

test('no window (due at or before sending) never reminds', () => {
  assert.deepEqual(reminderTimes(DUE, DUE), []);
  assert.deepEqual(reminderTimes(DUE, SENT), []);
});

test('slotsDue counts reached slots', () => {
  assert.equal(slotsDue(SENT, DUE, at('16:59')), 0);
  assert.equal(slotsDue(SENT, DUE, at('17:00')), 1);
  assert.equal(slotsDue(SENT, DUE, at('17:45')), 2);
});

function harness(requests, { claim = () => true } = {}) {
  const sent = [];
  const claims = [];
  return {
    sent, claims,
    ctx: {
      db: {
        listUpcomingPlanRequests: async () => requests.map((r) => ({
          id: r.id, updateTime: 'u1', data: r,
        })),
        patchDocIfUnchanged: async (path, fields) => {
          const ok = claim(path);
          if (ok) claims.push({ path, fields });
          return ok;
        },
        getDoc: async (p) => (p === 'users/requester' ? { name: 'Test Requester' } : null),
        listDocIds: async (p) => [`${p.split('/')[1]}-token`],
        deleteDoc: async () => {},
      },
      fcm: { send: async (token, message) => { sent.push({ token, message }); return { ok: true }; } },
    },
  };
}

const request = (o = {}) => ({
  id: 'r1',
  requesterUid: 'requester',
  plannerUid: 'planner',
  status: 'pending',
  createdAt: SENT.toISOString(),
  windowStartUtc: DUE.toISOString(),
  ...o,
});

test('the first reminder goes to the friend, tagged "Reminder"', async () => {
  const h = harness([request()]);
  await sendPlanRequestReminders(h.ctx, at('17:01'));
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].token, 'planner-token');
  assert.equal(h.sent[0].message.notification.title, 'Reminder');
  assert.equal(
    h.sent[0].message.notification.body,
    'Test Requester has requested you to plan for them. Click to view details.',
  );
  assert.equal(h.sent[0].message.data.planRequestId, 'r1');
  assert.equal(h.claims[0].fields.remindersSent, 1);
});

test('each reminder is sent once; the second follows at 75%', async () => {
  const once = harness([request({ remindersSent: 1 })]);
  await sendPlanRequestReminders(once.ctx, at('17:10'));
  assert.equal(once.sent.length, 0);

  const second = harness([request({ remindersSent: 1 })]);
  await sendPlanRequestReminders(second.ctx, at('17:31'));
  assert.equal(second.sent.length, 1);
  assert.equal(second.claims[0].fields.remindersSent, 2);

  const done = harness([request({ remindersSent: 2 })]);
  await sendPlanRequestReminders(done.ctx, at('17:59'));
  assert.equal(done.sent.length, 0);
});

test('a missed slot is skipped, not sent as a burst', async () => {
  const h = harness([request()]);
  await sendPlanRequestReminders(h.ctx, at('17:40'));
  assert.equal(h.sent.length, 1);
  assert.equal(h.claims[0].fields.remindersSent, 2);
});

test('only creating the plan stops them — declined/cancelled/fulfilled never remind', async () => {
  for (const status of ['fulfilled', 'declined', 'cancelled']) {
    const h = harness([request({ status })]);
    await sendPlanRequestReminders(h.ctx, at('17:31'));
    assert.equal(h.sent.length, 0, status);
  }
  // An opened-but-not-planned request is still pending → still reminded.
  const opened = harness([request({ viewedAt: at('16:30').toISOString() })]);
  await sendPlanRequestReminders(opened.ctx, at('17:01'));
  assert.equal(opened.sent.length, 1);
});

test('nothing at or after the due time', async () => {
  const h = harness([request()]);
  await sendPlanRequestReminders(h.ctx, DUE);
  assert.equal(h.sent.length, 0);
});

test('a lost claim sends nothing', async () => {
  const h = harness([request()], { claim: () => false });
  await sendPlanRequestReminders(h.ctx, at('17:01'));
  assert.equal(h.sent.length, 0);
});

test('the first push uses the same redesigned wording', async () => {
  const sent = [];
  const ctx = {
    db: {
      getDoc: async (p) => (p === 'users/requester'
        ? { name: 'Test Requester' }
        : p === 'planRequests/r1' ? { status: 'pending' } : null),
      listDocIds: async () => ['t'],
      deleteDoc: async () => {},
      patchDoc: async () => {},
    },
    fcm: { send: async (_t, m) => { sent.push(m); return { ok: true }; } },
  };
  await sendFriendNotification(ctx, {
    event: 'planRequested', fromUid: 'requester', toUid: 'planner', planRequestId: 'r1',
  });
  assert.equal(sent[0].notification.title, 'Plan request');
  assert.equal(sent[0].notification.body, planRequestBody('Test Requester'));
});
