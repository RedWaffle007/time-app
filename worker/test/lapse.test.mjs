import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  LAPSED_REJECT_REASON,
  LAPSED_SKIP_REASON,
  MIN_RESPONSE_WINDOW_MS,
  buildPlannerLapseMessage,
  buildTargetLapseMessage,
  endOfLocalDayMs,
  responseDeadlineMs,
  settleLapsedItems,
} from '../src/lapse.js';
import { ACTIVITY_CHANNEL_ID } from '../src/notify.js';
import { LAPSE_CRON, cronJobFor } from '../src/index.js';
import { makeFirestoreDb } from '../src/firestore-rest.js';

const HOUR = 60 * 60 * 1000;

// ---------------------------------------------------------------- deadline

test('deadline parity: the Worker matches every shared client fixture', () => {
  const fixture = JSON.parse(readFileSync(
    new URL('../../test/fixtures/response_deadlines.json', import.meta.url),
    'utf8',
  ));
  assert.ok(fixture.cases.length >= 15);
  for (const c of fixture.cases) {
    assert.equal(
      new Date(responseDeadlineMs(Date.parse(c.scheduled), c.zone)).toISOString(),
      c.deadline,
      c.name,
    );
  }
});

test('the deadline is never under two hours and never before local midnight', () => {
  const zones = ['Asia/Karachi', 'America/New_York', 'Asia/Kathmandu', 'Pacific/Auckland'];
  const start = Date.parse('2026-03-07T00:00:00Z'); // spans the NY DST switch
  for (const zone of zones) {
    for (let m = 0; m < 3 * 24 * 60; m += 7) {
      const scheduled = start + m * 60 * 1000;
      const deadline = responseDeadlineMs(scheduled, zone);
      assert.ok(deadline >= scheduled + MIN_RESPONSE_WINDOW_MS, `${zone} ${m}`);
      assert.ok(deadline >= endOfLocalDayMs(scheduled, zone), `${zone} ${m}`);
      assert.ok(deadline - scheduled <= 25 * HOUR, `${zone} ${m} at most a DST day`);
    }
  }
});

// ---------------------------------------------------------------- copy

const item = (overrides = {}) => ({
  targetUid: 'target',
  createdByUid: 'planner',
  groupId: '',
  title: 'Gym',
  status: 'approved',
  timezone: 'Asia/Karachi',
  scheduledInstantUtc: '2026-08-26T04:00:00.000Z', // 09:00 Karachi
  ...overrides,
});

test('target copy names the task and the planner', () => {
  const message = buildTargetLapseMessage(item(), {
    plannerName: 'Test Planner', groupName: null, selfPlanned: false,
  }, 'target', 'i1');
  assert.deepEqual(message.notification, {
    title: 'Task skipped automatically',
    body: "Gym, planned by Test Planner, was marked Skipped because you didn't respond in time.",
  });
  assert.deepEqual(message.data, {
    type: 'lapsed', event: 'lapsed', audience: 'target', targetUid: 'target', itemId: 'i1',
  });
  assert.deepEqual(message.android, {
    priority: 'high', notification: { channel_id: ACTIVITY_CHANNEL_ID },
  });
});

test('self-planned copy has no planner', () => {
  const message = buildTargetLapseMessage(item({ createdByUid: 'target' }), {
    plannerName: null, groupName: null, selfPlanned: true,
  }, 'target', 'i1');
  assert.equal(
    message.notification.body,
    "Gym was marked Skipped because you didn't respond in time.",
  );
});

test('planner copy names the person and the task', () => {
  const message = buildPlannerLapseMessage(item(), {
    targetName: 'Test Target', groupName: null,
  }, 'target', 'i1');
  assert.deepEqual(message.notification, {
    title: 'Task skipped automatically',
    body: "Test Target didn't respond to Gym, so it was marked Skipped.",
  });
  assert.equal(message.data.audience, 'planner');
});

test('group and emergency items say so in both messages', () => {
  const group = item({ groupId: 'g1' });
  const target = buildTargetLapseMessage(group, {
    plannerName: 'Test Planner', groupName: 'Team', selfPlanned: false,
  }, 'target', 'i1').notification;
  assert.equal(target.title, 'Group task skipped automatically');
  assert.equal(
    target.body,
    "Gym, planned by Test Planner in Team, was marked Skipped because you didn't respond in time.",
  );
  const planner = buildPlannerLapseMessage(group, {
    targetName: 'Test Target', groupName: 'Team',
  }, 'target', 'i1').notification;
  assert.equal(planner.body, "Test Target didn't respond to Gym in Team, so it was marked Skipped.");

  const emergency = buildPlannerLapseMessage(item({ tier: 'emergency' }), {
    targetName: 'Test Target', groupName: null,
  }, 'target', 'i1').notification;
  assert.equal(emergency.title, 'Emergency task skipped automatically');
  const both = buildTargetLapseMessage(item({ tier: 'emergency', groupId: 'g1' }), {
    plannerName: null, groupName: '', selfPlanned: false,
  }, 'target', 'i1').notification;
  assert.equal(both.title, 'Emergency group task skipped automatically');
  assert.match(both.body, /planned by Someone,/);
});

// ---------------------------------------------------------------- cron pass

// 26 Aug 09:00 Karachi → midnight deadline 26 Aug 19:00 UTC.
const AFTER = new Date('2026-08-26T19:01:00.000Z');
const BEFORE = new Date('2026-08-26T18:59:00.000Z');

function row(status, overrides = {}, rowOverrides = {}) {
  return {
    path: 'scheduleItems/target/items/i1',
    updateTime: 'v1',
    data: item({ status, ...overrides }),
    ...rowOverrides,
  };
}

function harness({ pending = [], approved = [] } = {}, docs = {}, {
  claim = () => true,
  tokens = { target: ['t-token'], planner: ['p-token'] },
} = {}) {
  const claims = [];
  const sent = [];
  const queries = [];
  const store = {
    'friendships/planner_target/plannerGrants/planner_target': { granted: true },
    'users/planner': { name: 'Test Planner' },
    'users/target': { name: 'Test Target' },
    ...docs,
  };
  return {
    claims, sent, queries,
    ctx: {
      db: {
        listItemsScheduledBetween: async (status, from, to, limit) => {
          queries.push({ status, from, to, limit });
          return status === 'pending' ? pending : approved;
        },
        patchDocIfUnchanged: async (path, fields, updateTime) => {
          claims.push({ path, fields, updateTime });
          return claim(path, fields);
        },
        getDoc: async (path) => store[path] ?? null,
        listDocIds: async (path) => tokens[path.split('/')[1]] ?? [],
        deleteDoc: async () => {},
      },
      fcm: {
        send: async (token, message) => {
          sent.push({ token, message });
          return { ok: true };
        },
      },
    },
  };
}

test('an unanswered approved item is skipped and BOTH people are told', async () => {
  const h = harness({ approved: [row('approved')] });
  const summary = await settleLapsedItems(h.ctx, AFTER);

  assert.equal(summary.skipped, 1);
  assert.equal(h.claims.length, 1);
  assert.equal(h.claims[0].updateTime, 'v1');
  assert.equal(h.claims[0].fields.outcome.result, 'skipped');
  assert.equal(h.claims[0].fields.outcome.skipReason, LAPSED_SKIP_REASON);
  assert.ok(h.claims[0].fields.outcome.skippedAt instanceof Date);
  assert.deepEqual(h.sent.map((s) => s.token), ['t-token', 'p-token']);
  assert.equal(h.sent[0].message.data.audience, 'target');
  assert.equal(h.sent[1].message.data.audience, 'planner');
  assert.match(h.sent[1].message.notification.body, /^Test Target didn't respond to Gym/);
  assert.match(h.sent[0].message.notification.body, /planned by Test Planner/);
});

test('nothing happens before the deadline', async () => {
  const h = harness({ pending: [row('pending')], approved: [row('approved')] });
  const summary = await settleLapsedItems(h.ctx, BEFORE);
  assert.deepEqual(summary, { rejected: 0, skipped: 0, sent: 0, cleaned: 0 });
  assert.equal(h.claims.length, 0);
});

test('a late-evening item waits for its two-hour minimum', async () => {
  // 23:50 Karachi (18:50 UTC): midnight at 19:00 UTC is too soon.
  const late = row('approved', { scheduledInstantUtc: '2026-08-26T18:50:00.000Z' });
  const early = harness({ approved: [late] });
  await settleLapsedItems(early.ctx, new Date('2026-08-26T20:49:00.000Z'));
  assert.equal(early.claims.length, 0);
  const due = harness({ approved: [late] });
  await settleLapsedItems(due.ctx, new Date('2026-08-26T20:50:00.000Z'));
  assert.equal(due.claims.length, 1);
});

test('a Done/Skip racing the lapse wins: failed claim, no notification', async () => {
  const h = harness({ approved: [row('approved')] }, {}, { claim: () => false });
  const summary = await settleLapsedItems(h.ctx, AFTER);
  assert.equal(summary.skipped, 0);
  assert.equal(h.sent.length, 0);
});

test('items that already have an outcome, or the wrong shape, are left alone', async () => {
  const cases = [
    row('approved', { outcome: { result: 'done' } }),
    row('approved', { outcome: { result: 'skipped', skipReason: 'Busy' } }),
    row('approved', {}, { path: 'elsewhere/target/items/i1' }),
    row('approved', { targetUid: 'someone-else' }),
    row('approved', {}, { updateTime: undefined }),
    row('approved', { scheduledInstantUtc: 'not-a-date' }),
    row('rejected'),
  ];
  for (const r of cases) {
    const h = harness({ approved: [r] });
    await settleLapsedItems(h.ctx, AFTER);
    assert.equal(h.claims.length, 0, JSON.stringify(r));
  }
});

test('an unapproved plan is rejected silently at the same deadline', async () => {
  const h = harness({ pending: [row('pending')] });
  const summary = await settleLapsedItems(h.ctx, AFTER);
  assert.equal(summary.rejected, 1);
  assert.equal(h.claims[0].fields.status, 'rejected');
  assert.equal(h.claims[0].fields.rejectionReason, LAPSED_REJECT_REASON);
  assert.equal(h.sent.length, 0, 'the planner is not told about a lapsed approval');
});

test('a self-planned lapse tells only the person', async () => {
  const self = row('approved', { createdByUid: 'target' });
  const h = harness({ approved: [self] });
  await settleLapsedItems(h.ctx, AFTER);
  assert.deepEqual(h.sent.map((s) => s.token), ['t-token']);
  assert.equal(
    h.sent[0].message.notification.body,
    "Gym was marked Skipped because you didn't respond in time.",
  );
});

test('a revoked grant still settles the item and tells the person, not the planner', async () => {
  const h = harness({ approved: [row('approved')] }, {
    'friendships/planner_target/plannerGrants/planner_target': { granted: false },
  });
  const summary = await settleLapsedItems(h.ctx, AFTER);
  assert.equal(summary.skipped, 1);
  assert.deepEqual(h.sent.map((s) => s.token), ['t-token']);
});

test('group items read the group name and grant', async () => {
  const h = harness({ approved: [row('approved', { groupId: 'g1' })] }, {
    'groups/g1': { name: 'Team' },
    'groups/g1/plannerGrants/planner_target': { granted: true },
  });
  await settleLapsedItems(h.ctx, AFTER);
  assert.equal(h.sent.length, 2);
  assert.equal(h.sent[1].message.notification.title, 'Group task skipped automatically');
  assert.match(h.sent[1].message.notification.body, / in Team, so it was marked Skipped\.$/);
});

test('the query window is two hours back to fifty hours back', async () => {
  const h = harness();
  await settleLapsedItems(h.ctx, AFTER);
  assert.deepEqual(h.queries.map((q) => q.status), ['pending', 'approved']);
  const { from, to } = h.queries[0];
  assert.equal(Date.parse(to), AFTER.getTime() - MIN_RESPONSE_WINDOW_MS);
  assert.equal(Date.parse(from), AFTER.getTime() - 50 * HOUR);
});

test('per-run caps bound the work', async () => {
  const many = (status) => Array.from({ length: 12 }, (_, i) =>
    row(status, {}, { path: `scheduleItems/target/items/i${i}` }));
  const h = harness({ pending: many('pending'), approved: many('approved') });
  const summary = await settleLapsedItems(h.ctx, AFTER, { maxSkips: 2, maxRejects: 4 });
  assert.equal(summary.rejected, 4);
  assert.equal(summary.skipped, 2);
});

test('the lapse runs on its own every-two-minutes cron', () => {
  assert.equal(LAPSE_CRON, '*/2 * * * *');
  assert.equal(cronJobFor(LAPSE_CRON), 'lapse');
  const toml = readFileSync(new URL('../wrangler.toml', import.meta.url), 'utf8');
  assert.ok(toml.includes('"*/2 * * * *"'));
});

// ---------------------------------------------------------------- REST shape


async function withFetch(respond, body) {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return respond(url, init);
  };
  try {
    await body(calls);
  } finally {
    globalThis.fetch = original;
  }
}

test('the range query asks for one status scheduled in (from, to]', async () => {
  await withFetch(() => new Response('[]', { status: 200 }), async (calls) => {
    await makeFirestoreDb('p', 'token').listItemsScheduledBetween(
      'approved', '2026-01-01T00:00:00.000Z', '2026-01-02T00:00:00.000Z', 7,
    );
    const q = JSON.parse(calls[0].init.body).structuredQuery;
    assert.deepEqual(q.from, [{ collectionId: 'items', allDescendants: true }]);
    assert.equal(q.limit, 7);
    const [status, from, to] = q.where.compositeFilter.filters.map((f) => f.fieldFilter);
    assert.deepEqual(status.value, { stringValue: 'approved' });
    assert.equal(from.op, 'GREATER_THAN');
    assert.equal(from.value.timestampValue, '2026-01-01T00:00:00.000Z');
    assert.equal(to.op, 'LESS_THAN_OR_EQUAL');
    assert.equal(to.value.timestampValue, '2026-01-02T00:00:00.000Z');
  });
});

test('the outcome map is written as a Firestore map, conditionally', async () => {
  await withFetch(() => new Response('{}', { status: 200 }), async (calls) => {
    const at = new Date('2026-01-01T00:00:00.000Z');
    const ok = await makeFirestoreDb('p', 'token').patchDocIfUnchanged(
      'scheduleItems/t/items/i',
      { outcome: { result: 'skipped', skippedAt: at, skipReason: 'Did not respond' } },
      'v1',
    );
    assert.equal(ok, true);
    assert.match(calls[0].url, /updateMask\.fieldPaths=outcome/);
    assert.match(calls[0].url, /currentDocument\.updateTime=v1/);
    assert.deepEqual(JSON.parse(calls[0].init.body).fields.outcome, {
      mapValue: {
        fields: {
          result: { stringValue: 'skipped' },
          skippedAt: { timestampValue: '2026-01-01T00:00:00.000Z' },
          skipReason: { stringValue: 'Did not respond' },
        },
      },
    });
  });
});
