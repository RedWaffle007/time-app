import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  MAX_APPROVAL_REMINDERS,
  MIN_REMINDER_GAP_MS,
  approvalReminderTimes,
  buildApprovalReminderMessage,
  buildPlannerPendingMessage,
  dueReminderIndex,
  sendDueApprovalReminders,
} from '../src/approval-reminders.js';
import { ACTIVITY_CHANNEL_ID } from '../src/notify.js';
import { APPROVAL_REMINDER_CRON, cronJobFor } from '../src/index.js';
import { makeFirestoreDb } from '../src/firestore-rest.js';

const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const T0 = Date.parse('2030-03-01T08:00:00.000Z');

const at = (ms) => new Date(ms);
const offsets = (times, base = T0) => times.map((t) => (t - base) / MIN);

// ---------------------------------------------------------------- timing

test('under 10 minutes: one reminder at the halfway point', () => {
  assert.deepEqual(offsets(approvalReminderTimes(T0, T0 + 5 * MIN)), [2.5]);
  assert.deepEqual(offsets(approvalReminderTimes(T0, T0 + 1 * MIN)), [0.5]);
  assert.deepEqual(offsets(approvalReminderTimes(T0, T0 + 9 * MIN)), [4.5]);
});

test('10 minutes to 2 hours: halfway plus a final one shortly before', () => {
  // 30 min: half at 15, final at due − 3 min (10% = 3 min).
  assert.deepEqual(offsets(approvalReminderTimes(T0, T0 + 30 * MIN)), [15, 27]);
  // 10 min exactly: half at 5, final at due − 3 (clamped up from 1).
  assert.deepEqual(offsets(approvalReminderTimes(T0, T0 + 10 * MIN)), [5, 7]);
  // 60 min: 10% = 6 min before.
  assert.deepEqual(offsets(approvalReminderTimes(T0, T0 + 60 * MIN)), [30, 54]);
  // 119 min: 10% = 11.9 → clamped to 10 before.
  assert.deepEqual(offsets(approvalReminderTimes(T0, T0 + 119 * MIN)), [59.5, 109]);
});

test('2 hours and more: halfway, one hour before, ten minutes before', () => {
  assert.deepEqual(
    offsets(approvalReminderTimes(T0, T0 + 12 * HOUR)),
    [6 * 60, 11 * 60, 12 * 60 - 10],
  );
  assert.deepEqual(
    offsets(approvalReminderTimes(T0, T0 + 3 * HOUR)),
    [90, 120, 170],
  );
});

test('exactly 2 hours: halfway and one-hour-before coincide, so one is dropped', () => {
  assert.deepEqual(offsets(approvalReminderTimes(T0, T0 + 2 * HOUR)), [60, 110]);
});

test('invariants hold across every window from 1 minute to 48 hours', () => {
  for (let minutes = 1; minutes <= 48 * 60; minutes += 1) {
    const due = T0 + minutes * MIN;
    const times = approvalReminderTimes(T0, due);
    assert.ok(times.length >= 1, `${minutes}m has a reminder`);
    assert.ok(times.length <= MAX_APPROVAL_REMINDERS, `${minutes}m capped`);
    for (let i = 0; i < times.length; i++) {
      assert.ok(times[i] > T0 && times[i] < due, `${minutes}m inside window`);
      if (i > 0) {
        assert.ok(times[i] - times[i - 1] >= MIN_REMINDER_GAP_MS,
          `${minutes}m spacing`);
      }
    }
    // The final reminder is always the one closest to the deadline, and never
    // more than an hour before it (except the single halfway one < 10 min).
    const final = times[times.length - 1];
    assert.ok(due - final <= Math.max(10 * MIN, (due - T0) / 2), `${minutes}m final`);
  }
});

test('no reminders for empty, inverted or unparsable windows', () => {
  assert.deepEqual(approvalReminderTimes(T0, T0), []);
  assert.deepEqual(approvalReminderTimes(T0, T0 - MIN), []);
  assert.deepEqual(approvalReminderTimes(NaN, T0), []);
  assert.deepEqual(approvalReminderTimes(T0, NaN), []);
});

test('timing is in absolute instants, so a DST change inside the window is irrelevant', () => {
  // 2030-03-10 is a US spring-forward day; the window is measured in UTC ms.
  const created = Date.parse('2030-03-10T06:00:00Z');
  const due = Date.parse('2030-03-10T10:00:00Z');
  assert.deepEqual(offsets(approvalReminderTimes(created, due), created), [120, 180, 230]);
});

test('only the latest past slot is due, and sent slots never repeat', () => {
  const times = [10, 20, 30];
  assert.equal(dueReminderIndex(times, 0, 5), -1);
  assert.equal(dueReminderIndex(times, 0, 10), 0);
  assert.equal(dueReminderIndex(times, 1, 15), -1);
  assert.equal(dueReminderIndex(times, 1, 20), 1);
  // Worker down across two slots → one reminder (the latest), not a burst.
  assert.equal(dueReminderIndex(times, 0, 25), 1);
  assert.equal(dueReminderIndex(times, 3, 100), -1);
});

// ---------------------------------------------------------------- copy

test('reminder copy names the task and planner, and labels group plans', () => {
  const friend = buildApprovalReminderMessage({
    title: 'Gym', plannerName: 'Test Planner', groupName: null,
    isFinal: false, targetUid: 't', itemId: 'i',
  });
  assert.deepEqual(friend.notification, {
    title: 'Waiting for your approval',
    body: 'Task: Gym planned by Test Planner is waiting for your approval.',
  });
  assert.deepEqual(friend.data, {
    type: 'approvalReminder', event: 'approvalReminder', targetUid: 't', itemId: 'i',
  });
  assert.deepEqual(friend.android, {
    priority: 'high', notification: { channel_id: ACTIVITY_CHANNEL_ID },
  });

  const group = buildApprovalReminderMessage({
    title: 'Gym', plannerName: 'Test Planner', groupName: 'Team',
    isFinal: true, targetUid: 't', itemId: 'i',
  });
  assert.deepEqual(group.notification, {
    title: 'Due soon: waiting for your approval',
    body: 'Group task: Gym planned by Test Planner in Team is waiting for your approval.',
  });

  const unnamed = buildApprovalReminderMessage({
    title: '', plannerName: null, groupName: '',
    isFinal: false, targetUid: 't', itemId: 'i',
  });
  assert.equal(
    unnamed.notification.body,
    'Group task: your scheduled item planned by Someone is waiting for your approval.',
  );
});

// ---------------------------------------------------------------- cron pass

function pendingRow(overrides = {}, rowOverrides = {}) {
  return {
    path: 'scheduleItems/target/items/item-1',
    updateTime: 'v1',
    createTime: at(T0).toISOString(),
    data: {
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: '',
      title: 'Gym',
      status: 'pending',
      scheduledInstantUtc: at(T0 + 30 * MIN).toISOString(),
      createdAt: at(T0).toISOString(),
      ...overrides,
    },
    ...rowOverrides,
  };
}

function harness(rows, docs = {}, {
  tokens = ['token-1'],
  claim = () => true,
  tokenResults = {},
} = {}) {
  const sent = [];
  const claims = [];
  const deleted = [];
  const reads = [];
  const store = {
    'friendships/planner_target/plannerGrants/planner_target': { granted: true },
    'users/planner': { name: 'Test Planner' },
    ...docs,
  };
  return {
    sent, claims, deleted, reads,
    ctx: {
      db: {
        listPendingItems: async () => rows,
        getDoc: async (path) => {
          reads.push(path);
          return store[path] ?? null;
        },
        listDocIds: async () => tokens,
        deleteDoc: async (path) => deleted.push(path),
        patchDocIfUnchanged: async (path, fields, updateTime) => {
          claims.push({ path, fields, updateTime });
          return claim(path, fields, updateTime);
        },
      },
      fcm: {
        send: async (token, message) => {
          sent.push({ token, message });
          return tokenResults[token] ?? { ok: true };
        },
      },
    },
  };
}

test('a due reminder is claimed against the queried version, then sent', async () => {
  const h = harness([pendingRow()]);
  const summary = await sendDueApprovalReminders(h.ctx, at(T0 + 15 * MIN));

  assert.deepEqual(summary, {
    considered: 1, claimed: 1, sent: 1, cleaned: 0, plannerHeadsUps: 0,
  });
  assert.equal(h.claims[0].path, 'scheduleItems/target/items/item-1');
  assert.equal(h.claims[0].updateTime, 'v1');
  assert.equal(h.claims[0].fields.approvalRemindersSent, 1);
  assert.equal(
    h.sent[0].message.notification.body,
    'Task: Gym planned by Test Planner is waiting for your approval.',
  );
  assert.equal(h.sent[0].message.notification.title, 'Waiting for your approval');
});

test('the final slot uses the due-soon title', async () => {
  const h = harness([pendingRow({ approvalRemindersSent: 1 })]);
  await sendDueApprovalReminders(h.ctx, at(T0 + 27 * MIN));
  assert.equal(h.claims[0].fields.approvalRemindersSent, 2);
  assert.equal(h.sent[0].message.notification.title, 'Due soon: waiting for your approval');
});

test('a decision racing the claim stops the reminder (claim fails, nothing sent)', async () => {
  const h = harness([pendingRow()], {}, { claim: () => false });
  const summary = await sendDueApprovalReminders(h.ctx, at(T0 + 15 * MIN));
  assert.equal(summary.claimed, 0);
  assert.equal(h.sent.length, 0);
});

test('decided, withdrawn, self-planned, past-due or not-yet-due items never remind', async () => {
  const now = at(T0 + 15 * MIN);
  const cases = [
    pendingRow({ status: 'approved' }),
    pendingRow({ status: 'rejected' }),
    pendingRow({ status: 'withdrawn' }),
    pendingRow({ createdByUid: 'target' }),
    pendingRow({ scheduledInstantUtc: at(T0 + 14 * MIN).toISOString() }),
    pendingRow({ approvalRemindersSent: 1 }),
    pendingRow({ approvalRemindersSent: 2 }),
    pendingRow({}, { path: 'otherRoot/target/items/item-1' }),
    pendingRow({ targetUid: 'someone-else' }),
    pendingRow({}, { updateTime: undefined }),
  ];
  for (const row of cases) {
    const h = harness([row]);
    await sendDueApprovalReminders(h.ctx, now);
    assert.equal(h.claims.length, 0, JSON.stringify(row));
    assert.equal(h.sent.length, 0, JSON.stringify(row));
  }
  // Not yet due: 30-minute plan at minute 10 (first slot is minute 15).
  const early = harness([pendingRow()]);
  await sendDueApprovalReminders(early.ctx, at(T0 + 10 * MIN));
  assert.equal(early.sent.length, 0);
});

test('a revoked grant means no reminder and no claim', async () => {
  const h = harness([pendingRow()], {
    'friendships/planner_target/plannerGrants/planner_target': { granted: false },
  });
  await sendDueApprovalReminders(h.ctx, at(T0 + 15 * MIN));
  assert.equal(h.claims.length, 0);
  assert.equal(h.sent.length, 0);
});

test('group plans check the group grant and are labelled with the group', async () => {
  const h = harness([pendingRow({ groupId: 'g1' })], {
    'groups/g1/plannerGrants/planner_target': { granted: true },
    'groups/g1': { name: 'Team' },
  });
  await sendDueApprovalReminders(h.ctx, at(T0 + 15 * MIN));
  assert.ok(h.reads.includes('groups/g1/plannerGrants/planner_target'));
  assert.equal(
    h.sent[0].message.notification.body,
    'Group task: Gym planned by Test Planner in Team is waiting for your approval.',
  );
});

test('a missing createdAt falls back to the document create time', async () => {
  const h = harness([pendingRow({ createdAt: undefined })]);
  await sendDueApprovalReminders(h.ctx, at(T0 + 15 * MIN));
  assert.equal(h.sent.length, 1);
});

test('dead tokens are cleaned; a pass stops at the per-run budget', async () => {
  const cleaned = harness([pendingRow()], {}, {
    tokens: ['good', 'gone'],
    tokenResults: { gone: { error: 'UNREGISTERED' } },
  });
  const summary = await sendDueApprovalReminders(cleaned.ctx, at(T0 + 15 * MIN));
  assert.equal(summary.sent, 1);
  assert.deepEqual(cleaned.deleted, ['users/target/fcmTokens/gone']);

  const rows = Array.from({ length: 10 }, (_, i) =>
    pendingRow({}, { path: `scheduleItems/target/items/item-${i}` }));
  const budget = harness(rows);
  const capped = await sendDueApprovalReminders(budget.ctx, at(T0 + 15 * MIN), {
    maxReminders: 3,
  });
  assert.equal(capped.claimed, 3);
  assert.equal(budget.sent.length, 3);
});

// ---------------------------------------------------------------- wiring

test('the every-minute cron runs reminders; the 5-minute cron stays inactivity', () => {
  assert.equal(cronJobFor(APPROVAL_REMINDER_CRON), 'approvalReminders');
  assert.equal(cronJobFor('*/5 * * * *'), 'inactivity');
  assert.equal(cronJobFor(undefined), 'inactivity');

  const toml = readFileSync(new URL('../wrangler.toml', import.meta.url), 'utf8');
  assert.match(toml, /crons = \["\*\/5 \* \* \* \*", "\* \* \* \* \*", "\*\/2 \* \* \* \*", "7 \* \* \* \*"\]/);
});

test('the pending-items query asks for pending items due after now, soonest first', async () => {
  const original = globalThis.fetch;
  let request;
  globalThis.fetch = async (url, init) => {
    request = { url, body: JSON.parse(init.body) };
    return new Response(JSON.stringify([
      {
        document: {
          name: 'projects/p/databases/(default)/documents/scheduleItems/u%201/items/i1',
          fields: { status: { stringValue: 'pending' } },
          updateTime: 'v9',
          createTime: '2030-01-01T00:00:00Z',
        },
      },
      { readTime: '2030-01-01T00:00:00Z' },
    ]), { status: 200 });
  };
  try {
    const rows = await makeFirestoreDb('p', 'token')
      .listPendingItems(at(T0), 25);
    const q = request.body.structuredQuery;
    assert.match(request.url, /:runQuery$/);
    assert.deepEqual(q.from, [{ collectionId: 'items', allDescendants: true }]);
    assert.equal(q.limit, 25);
    assert.deepEqual(q.orderBy[0].field, { fieldPath: 'scheduledInstantUtc' });
    const [status, due] = q.where.compositeFilter.filters;
    assert.deepEqual(status.fieldFilter.value, { stringValue: 'pending' });
    assert.equal(due.fieldFilter.op, 'GREATER_THAN');
    assert.equal(due.fieldFilter.value.timestampValue, at(T0).toISOString());
    assert.deepEqual(rows, [{
      path: 'scheduleItems/u 1/items/i1',
      data: { status: 'pending' },
      updateTime: 'v9',
      createTime: '2030-01-01T00:00:00Z',
    }]);
  } finally {
    globalThis.fetch = original;
  }
});

test('the composite index the query needs is declared', () => {
  const indexes = JSON.parse(readFileSync(
    new URL('../../firestore.indexes.json', import.meta.url), 'utf8',
  ));
  const found = indexes.indexes.some((i) =>
    i.collectionGroup === 'items' &&
    i.queryScope === 'COLLECTION_GROUP' &&
    JSON.stringify(i.fields) === JSON.stringify([
      { fieldPath: 'status', order: 'ASCENDING' },
      { fieldPath: 'scheduledInstantUtc', order: 'ASCENDING' },
    ]));
  assert.ok(found);
});

// ---------------------------------------------------------------- item 16

function tokensByUser(h) {
  // Map each sent message back to its recipient via the token lists below.
  return h.sent.map((s) => s.token);
}

function headsUpHarness(rows, docs = {}) {
  const h = harness(rows, {
    'users/target': { name: 'Test Target' },
    ...docs,
  });
  h.ctx.db.listDocIds = async (path) =>
    path === 'users/planner/fcmTokens' ? ['planner-token'] : ['target-token'];
  return h;
}

test('the FINAL reminder also gives the planner one heads-up', async () => {
  // 30-minute window: slots at 15 and 27 minutes; 27 is the final one.
  const h = headsUpHarness([pendingRow({ approvalRemindersSent: 1 })]);
  const summary = await sendDueApprovalReminders(h.ctx, at(T0 + 27 * MIN));

  assert.equal(summary.plannerHeadsUps, 1);
  assert.deepEqual(tokensByUser(h), ['target-token', 'planner-token']);
  assert.deepEqual(h.sent[1].message.notification, {
    title: 'Still waiting for approval',
    body: "Test Target hasn't approved Gym yet. It's due soon.",
  });
  assert.deepEqual(h.sent[1].message.data, {
    type: 'approvalPending',
    event: 'approvalPending',
    targetUid: 'target',
    itemId: 'item-1',
  });
});

test('earlier reminders never ping the planner', async () => {
  const h = headsUpHarness([pendingRow()]);
  const summary = await sendDueApprovalReminders(h.ctx, at(T0 + 15 * MIN));
  assert.equal(summary.plannerHeadsUps, 0);
  assert.deepEqual(tokensByUser(h), ['target-token']);
});

test('a one-reminder window: the only reminder is the final, so the planner hears once', async () => {
  const short = pendingRow({ scheduledInstantUtc: at(T0 + 5 * MIN).toISOString() });
  const h = headsUpHarness([short]);
  const summary = await sendDueApprovalReminders(h.ctx, at(T0 + 3 * MIN));
  assert.equal(summary.plannerHeadsUps, 1);
  assert.deepEqual(tokensByUser(h), ['target-token', 'planner-token']);
});

test('the heads-up never repeats: its slot is already claimed', async () => {
  const h = headsUpHarness([pendingRow({ approvalRemindersSent: 2 })]);
  const summary = await sendDueApprovalReminders(h.ctx, at(T0 + 29 * MIN));
  assert.equal(summary.plannerHeadsUps, 0);
  assert.equal(h.sent.length, 0);
});

test('a decision racing the final slot stops the heads-up too', async () => {
  const h = headsUpHarness([pendingRow({ approvalRemindersSent: 1 })]);
  h.ctx.db.patchDocIfUnchanged = async () => false;
  const summary = await sendDueApprovalReminders(h.ctx, at(T0 + 27 * MIN));
  assert.equal(summary.plannerHeadsUps, 0);
  assert.equal(h.sent.length, 0);
});

test('a revoked grant means no reminder and no heads-up', async () => {
  const h = headsUpHarness([pendingRow({ approvalRemindersSent: 1 })], {
    'friendships/planner_target/plannerGrants/planner_target': { granted: false },
  });
  await sendDueApprovalReminders(h.ctx, at(T0 + 27 * MIN));
  assert.equal(h.sent.length, 0);
});

test('heads-up copy: group label, fallbacks, no clock time', () => {
  const group = buildPlannerPendingMessage({
    title: 'Gym', targetName: 'Test Target', groupName: 'Team',
    targetUid: 't', itemId: 'i',
  }).notification;
  assert.equal(group.title, 'Group plan still waiting for approval');
  assert.equal(group.body, "Test Target hasn't approved Gym in Team yet. It's due soon.");

  const bare = buildPlannerPendingMessage({
    title: '', targetName: null, groupName: null, targetUid: 't', itemId: 'i',
  });
  assert.equal(bare.notification.body, "Someone hasn't approved your scheduled item yet. It's due soon.");
  assert.doesNotMatch(bare.notification.body, /\d/);
  assert.deepEqual(bare.android, {
    priority: 'high', notification: { channel_id: ACTIVITY_CHANNEL_ID },
  });
});
