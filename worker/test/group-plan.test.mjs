import assert from 'node:assert/strict';
import test from 'node:test';

import {
  busyMemberMessage,
  epochMinute,
  formatTimeIn,
  handleGroupPlanned,
  plannerSummaryMessage,
} from '../src/group-plan.js';

// Batch G item 4 (2026-09-27): a group plan that met double-booked members.
// Busy is only ever what Firestore says — never what the phone claims.

const NOW = new Date('2030-10-04T23:00:00Z');
const SIX_PM = new Date('2030-10-05T01:00:00Z'); // 18:00 Vancouver (PDT)
const MIN = epochMinute(SIX_PM);

function harness(extra = {}, { tokens = {} } = {}) {
  const docs = {
    'groups/g1': { name: 'Team', memberUids: ['planner', 'busy', 'free', 'self-planned'] },
    'users/planner': { name: 'Test Planner' },
    'users/busy': { name: 'Test Busy', homeTimezone: 'America/Vancouver' },
    'users/free': { name: 'Test Free', homeTimezone: 'Asia/Kolkata' },
    [`scheduleMinutes/busy/minutes/${MIN}`]: { itemId: 'theirs' },
    'scheduleItems/busy/items/theirs': {
      status: 'approved', createdByUid: 'someone', groupId: '',
    },
    ...extra,
  };
  const sent = [];
  const patched = [];
  return {
    sent, patched, docs,
    ctx: {
      now: NOW,
      db: {
        getDoc: async (p) => docs[p] ?? null,
        listDocIds: async (p) => tokens[p.split('/')[1]] ?? [`${p.split('/')[1]}-token`],
        deleteDoc: async () => {},
        patchDoc: async (path, fields) => { patched.push(path); docs[path] = fields; },
      },
      fcm: { send: async (token, message) => { sent.push({ token, message }); return { ok: true }; } },
    },
  };
}

const body = (busy, o = {}) => ({
  groupId: 'g1', title: 'Evacuate', setCount: 2, busy, ...o,
});

test('a verified busy member is told, in THEIR zone; the planner gets the summary', async () => {
  const h = harness();
  const res = await handleGroupPlanned(h.ctx, 'planner',
    body([{ uid: 'busy', instantUtc: SIX_PM.toISOString() }]));
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.busyUids, ['busy']);
  const toBusy = h.sent.find((s) => s.token === 'busy-token').message;
  assert.equal(
    toBusy.notification.body,
    'Group task "Evacuate" from Test Planner wasn\'t set for you at 6:00 PM. You already have a plan then.',
  );
  const toPlanner = h.sent.find((s) => s.token === 'planner-token').message;
  assert.equal(
    toPlanner.notification.body,
    'Your group task "Evacuate" is set for 2 members. 1 (Test Busy) was busy at that time and won\'t be alerted.',
  );
});

test('a false busy claim — a free minute — sends nothing to anyone', async () => {
  const h = harness();
  const res = await handleGroupPlanned(h.ctx, 'planner',
    body([{ uid: 'free', instantUtc: SIX_PM.toISOString() }]));
  assert.deepEqual(res.body.busyUids, []);
  assert.equal(h.sent.length, 0);
});

test('a minute held by a SETTLED plan, or by the planner\'s own copy, is not busy', async () => {
  const settled = harness({
    'scheduleItems/busy/items/theirs': {
      status: 'approved', createdByUid: 'someone', outcome: { result: 'done' },
    },
  });
  assert.deepEqual((await handleGroupPlanned(settled.ctx, 'planner',
    body([{ uid: 'busy', instantUtc: SIX_PM.toISOString() }]))).body.busyUids, []);

  const own = harness({
    'scheduleItems/busy/items/theirs': {
      status: 'approved', createdByUid: 'planner', groupId: 'g1',
    },
  });
  assert.deepEqual((await handleGroupPlanned(own.ctx, 'planner',
    body([{ uid: 'busy', instantUtc: SIX_PM.toISOString() }]))).body.busyUids, []);
});

test('a non-member caller is refused; a non-member target is ignored', async () => {
  const h = harness();
  const outsider = await handleGroupPlanned(h.ctx, 'outsider',
    body([{ uid: 'busy', instantUtc: SIX_PM.toISOString() }]));
  assert.equal(outsider.status, 403);

  const stranger = harness({
    [`scheduleMinutes/stranger/minutes/${MIN}`]: { itemId: 'x' },
    'scheduleItems/stranger/items/x': { status: 'approved', createdByUid: 'z' },
  });
  const res = await handleGroupPlanned(stranger.ctx, 'planner',
    body([{ uid: 'stranger', instantUtc: SIX_PM.toISOString() }]));
  assert.deepEqual(res.body.busyUids, []);
});

test('each member is told once per plan minute', async () => {
  const h = harness();
  const b = body([{ uid: 'busy', instantUtc: SIX_PM.toISOString() }]);
  await handleGroupPlanned(h.ctx, 'planner', b);
  const first = h.sent.filter((s) => s.token === 'busy-token').length;
  await handleGroupPlanned(h.ctx, 'planner', b);
  assert.equal(h.sent.filter((s) => s.token === 'busy-token').length, first);
});

test('a long-past instant, a malformed body, or too many entries is refused', async () => {
  const h = harness();
  const past = await handleGroupPlanned(h.ctx, 'planner',
    body([{ uid: 'busy', instantUtc: '2030-10-04T20:00:00Z' }]));
  assert.deepEqual(past.body.busyUids, []);
  for (const bad of [
    body('nope'),
    body([], { groupId: 'a/b' }),
    body([], { setCount: -1 }),
    body(Array.from({ length: 51 }, () => ({ uid: 'busy', instantUtc: SIX_PM.toISOString() }))),
  ]) {
    assert.equal((await handleGroupPlanned(h.ctx, 'planner', bad)).status, 400);
  }
});

test('copy helpers and zone formatting', () => {
  assert.equal(formatTimeIn(SIX_PM, 'America/Vancouver'), '6:00 PM');
  assert.equal(formatTimeIn(SIX_PM, 'Asia/Kolkata'), '6:30 AM');
  assert.match(formatTimeIn(SIX_PM, 'Not/AZone'), /UTC/);
  assert.equal(
    busyMemberMessage({ title: 'T', plannerName: 'P', time: '9:00 AM' }).title,
    'Group task not set',
  );
  assert.match(
    plannerSummaryMessage({ title: 'T', setCount: 1, busyNames: ['A', 'B'] }).body,
    /set for 1 member\. 2 \(A, B\) were busy/,
  );
});
