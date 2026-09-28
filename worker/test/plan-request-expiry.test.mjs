import assert from 'node:assert/strict';
import test from 'node:test';

import {
  EXPIRY_LOOKBACK_MS,
  expirePlanRequests,
  expiryMessages,
  lastStart,
} from '../src/plan-request-expiry.js';

// 2026-09-28: a plan request whose minute passes unplanned closes as
// `expired`, and both people are told in their own zone.

const DUE = new Date('2030-10-04T18:00:00Z');
const after = (minutes) => new Date(DUE.getTime() + minutes * 60 * 1000);

const USERS = {
  'users/requester': { name: 'Test Requester', homeTimezone: 'Asia/Kolkata' },
  'users/planner': { name: 'Test Planner', homeTimezone: 'America/Chicago' },
};

function harness(requests, { claim = () => true, users = USERS } = {}) {
  const sent = [];
  const claims = [];
  const queries = [];
  return {
    sent, claims, queries,
    ctx: {
      db: {
        listDuePlanRequests: async (since, now) => {
          queries.push({ since, now });
          return requests.map((r) => ({ id: r.id, updateTime: 'u1', data: r }));
        },
        patchDocIfUnchanged: async (path, fields, updateTime) => {
          const ok = claim(path);
          if (ok) claims.push({ path, fields, updateTime });
          return ok;
        },
        getDoc: async (p) => users[p] || null,
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
  title: 'Take the pills',
  timezone: 'Asia/Kolkata',
  windowStartUtc: DUE.toISOString(),
  ...o,
});

test('the approved wording', () => {
  const m = expiryMessages({
    requesterName: 'X', plannerName: 'Y', task: 'Gym',
    timeForRequester: '6:00 PM', timeForPlanner: '1:00 PM',
  });
  assert.deepEqual(m.requester, {
    title: 'Plan request not set',
    body: 'Y didn\'t set your alarm for "Gym" at 6:00 PM. The requested time has passed.',
  });
  assert.deepEqual(m.planner, {
    title: 'Plan request missed',
    body: 'You didn\'t set X\'s alarm for "Gym" at 1:00 PM. The requested time has passed.',
  });
});

test('an open request past its minute expires, claimed on its updateTime', async () => {
  const h = harness([request()]);
  const result = await expirePlanRequests(h.ctx, after(1));
  assert.equal(h.claims.length, 1);
  assert.equal(h.claims[0].path, 'planRequests/r1');
  assert.equal(h.claims[0].fields.status, 'expired');
  assert.equal(h.claims[0].updateTime, 'u1');
  assert.deepEqual(result, { scanned: 1, expired: 1, sent: 2 });
});

test('both people are told, each in their own zone', async () => {
  const h = harness([request()]);
  await expirePlanRequests(h.ctx, after(1));
  const toRequester = h.sent.find((s) => s.token === 'requester-token').message;
  const toPlanner = h.sent.find((s) => s.token === 'planner-token').message;
  assert.equal(toRequester.notification.title, 'Plan request not set');
  assert.equal(toRequester.notification.body,
    'Test Planner didn\'t set your alarm for "Take the pills" at 11:30 PM. '
    + 'The requested time has passed.');
  assert.equal(toPlanner.notification.title, 'Plan request missed');
  assert.equal(toPlanner.notification.body,
    'You didn\'t set Test Requester\'s alarm for "Take the pills" at 1:00 PM. '
    + 'The requested time has passed.');
  assert.equal(toRequester.data.type, 'planRequestExpired');
  assert.equal(toRequester.data.audience, 'requester');
  assert.equal(toPlanner.data.audience, 'planner');
  assert.equal(toPlanner.data.planRequestId, 'r1');
  assert.equal(toPlanner.android.notification.channel_id, 'planner_activity');
});

test('an in-progress (legacy flexible) request expires too', async () => {
  const h = harness([request({ status: 'inProgress' })]);
  const result = await expirePlanRequests(h.ctx, after(1));
  assert.equal(result.expired, 1);
});

test('finished requests are never touched', async () => {
  for (const status of ['fulfilled', 'declined', 'cancelled', 'expired']) {
    const h = harness([request({ status })]);
    const result = await expirePlanRequests(h.ctx, after(1));
    assert.equal(h.claims.length, 0, status);
    assert.equal(h.sent.length, 0, status);
    assert.equal(result.expired, 0, status);
  }
});

test('a request whose minute has not arrived stays open', async () => {
  const h = harness([request()]);
  await expirePlanRequests(h.ctx, after(-1));
  assert.equal(h.claims.length, 0);
});

test('losing the claim (a plan landed, or another run won) sends nothing', async () => {
  const h = harness([request()], { claim: () => false });
  const result = await expirePlanRequests(h.ctx, after(1));
  assert.equal(h.sent.length, 0);
  assert.equal(result.expired, 0);
});

test('a long-past request expires silently', async () => {
  const h = harness([request()]);
  const result = await expirePlanRequests(h.ctx, after(31));
  assert.equal(result.expired, 1);
  assert.equal(h.sent.length, 0);
});

test('the query looks back 24 hours', async () => {
  const h = harness([]);
  const now = after(1);
  await expirePlanRequests(h.ctx, now);
  assert.equal(h.queries[0].now, now);
  assert.equal(now.getTime() - h.queries[0].since.getTime(), EXPIRY_LOOKBACK_MS);
});

test('missing profiles fall back to neutral names and the request zone', async () => {
  const h = harness([request()], { users: {} });
  await expirePlanRequests(h.ctx, after(1));
  const toRequester = h.sent.find((s) => s.token === 'requester-token').message;
  const toPlanner = h.sent.find((s) => s.token === 'planner-token').message;
  assert.match(toRequester.notification.body, /^Your friend didn't set your alarm .* at 11:30 PM\./);
  assert.match(toPlanner.notification.body, /^You didn't set your friend's alarm .* at 6:00 PM\./);
});

test('a dead token is removed', async () => {
  const h = harness([request()]);
  const deleted = [];
  h.ctx.db.deleteDoc = async (p) => { deleted.push(p); };
  h.ctx.fcm.send = async () => ({ ok: false, error: 'UNREGISTERED' });
  await expirePlanRequests(h.ctx, after(1));
  assert.deepEqual(deleted.sort(), [
    'users/planner/fcmTokens/planner-token',
    'users/requester/fcmTokens/requester-token',
  ]);
});

test('the due minute is the last start that still fits the window', () => {
  const onePlan = request({
    windowEndUtc: after(1).toISOString(), durationMinutes: 1,
  });
  assert.equal(lastStart(onePlan).toISOString(), DUE.toISOString());
  const flexible = request({
    windowEndUtc: after(120).toISOString(), durationMinutes: 30,
  });
  assert.equal(lastStart(flexible).toISOString(), after(90).toISOString());
});

test('a legacy flexible window stays open until its last start', async () => {
  const flexible = request({
    status: 'inProgress',
    windowEndUtc: after(120).toISOString(),
    durationMinutes: 30,
  });
  const early = harness([flexible]);
  await expirePlanRequests(early.ctx, after(60));
  assert.equal(early.claims.length, 0);
  const late = harness([flexible]);
  await expirePlanRequests(late.ctx, after(91));
  assert.equal(late.claims.length, 1);
});
