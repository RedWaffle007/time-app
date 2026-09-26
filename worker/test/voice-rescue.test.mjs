import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  PLANNER_NOTICE_WINDOW_MS,
  RESCUE_PUSH_WINDOW_MS,
  buildVoiceFetchCommand,
  buildVoiceUndeliveredMessage,
  rescueUndeliveredVoiceNotes,
} from '../src/voice-rescue.js';
import { MAX_REJECTS_PER_RUN, MAX_SKIPS_PER_RUN } from '../src/lapse.js';

const MIN = 60 * 1000;
const NOW = new Date('2026-10-01T09:00:00.000Z');
const at = (minutes) => new Date(NOW.getTime() + minutes * MIN).toISOString();

function row(overrides = {}, rowOverrides = {}) {
  return {
    path: 'scheduleItems/target/items/item-1',
    updateTime: 'v1',
    data: {
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: '',
      title: 'Wake up',
      status: 'approved',
      scheduledInstantUtc: at(20),
      voiceNote: { sha256: 'a'.repeat(64), durationMs: 12000, sizeBytes: 9000 },
      ...overrides,
    },
    ...rowOverrides,
  };
}

function harness(rows, docs = {}, { claim = () => true } = {}) {
  const sent = [];
  const claims = [];
  const queries = [];
  const store = {
    'friendships/planner_target/plannerGrants/planner_target': { granted: true },
    'users/target': { name: 'Test Target' },
    ...docs,
  };
  return {
    sent, claims, queries,
    ctx: {
      db: {
        listItemsScheduledBetween: async (status, from, to, limit) => {
          queries.push({ status, from, to, limit });
          return rows;
        },
        patchDocIfUnchanged: async (path, fields, updateTime) => {
          claims.push({ path, fields, updateTime });
          return claim(fields);
        },
        getDoc: async (path) => store[path] ?? null,
        listDocIds: async (path) => [`${path.split('/')[1]}-token`],
        deleteDoc: async () => {},
      },
      fcm: { send: async (token, message) => { sent.push({ token, message }); return { ok: true }; } },
    },
  };
}

test('the window queried is approved items due in the next 30 minutes', async () => {
  const h = harness([]);
  await rescueUndeliveredVoiceNotes(h.ctx, NOW);
  assert.equal(h.queries[0].status, 'approved');
  assert.equal(h.queries[0].from, NOW.toISOString());
  assert.equal(Date.parse(h.queries[0].to) - NOW.getTime(), RESCUE_PUSH_WINDOW_MS);
});

test('an undelivered note gets ONE background fetch push to the target', async () => {
  const h = harness([row()]);
  const summary = await rescueUndeliveredVoiceNotes(h.ctx, NOW);
  assert.equal(summary.pushes, 1);
  assert.deepEqual(h.claims[0].fields, { voiceRescuePushAt: NOW });
  assert.equal(h.claims[0].updateTime, 'v1');
  assert.equal(h.sent[0].token, 'target-token');
  assert.deepEqual(h.sent[0].message, buildVoiceFetchCommand('target', 'item-1'));
  assert.equal(h.sent[0].message.notification, undefined, 'data-only');
  assert.equal(h.sent[0].message.android.priority, 'high');
});

test('within 10 minutes, after the push, the planner is warned once', async () => {
  const h = harness([row({ scheduledInstantUtc: at(8), voiceRescuePushAt: at(-5) })]);
  const summary = await rescueUndeliveredVoiceNotes(h.ctx, NOW);
  assert.equal(summary.notices, 1);
  assert.deepEqual(h.claims[0].fields, { notifiedVoiceUndelivered: true });
  assert.equal(h.sent[0].token, 'planner-token');
  assert.deepEqual(h.sent[0].message.notification, {
    title: 'Voice note not delivered yet',
    body: "Your voice note hasn't reached Test Target's phone yet. If it doesn't arrive, Wake up will ring with the normal ringtone.",
  });
  assert.equal(h.sent[0].message.data.event, 'voiceUndelivered');
});

test('no warning before 10 minutes, and never twice', async () => {
  const early = harness([row({ scheduledInstantUtc: at(15), voiceRescuePushAt: at(-5) })]);
  await rescueUndeliveredVoiceNotes(early.ctx, NOW);
  assert.equal(early.sent.length, 0);
  const twice = harness([row({
    scheduledInstantUtc: at(8), voiceRescuePushAt: at(-5), notifiedVoiceUndelivered: true,
  })]);
  await rescueUndeliveredVoiceNotes(twice.ctx, NOW);
  assert.equal(twice.sent.length, 0);
  assert.equal(PLANNER_NOTICE_WINDOW_MS, 10 * MIN);
});

test('a delivered, settled, self, note-less or past item is left alone', async () => {
  const cases = [
    row({ voiceNote: { sha256: 'x', deliveredAt: at(-60) } }),
    row({ voiceNote: undefined }),
    row({ outcome: { result: 'done' } }),
    row({ createdByUid: 'target' }),
    row({ status: 'pending' }),
    row({ scheduledInstantUtc: at(-1) }),
    row({}, { path: 'elsewhere/target/items/item-1' }),
    row({}, { updateTime: undefined }),
  ];
  for (const r of cases) {
    const h = harness([r]);
    await rescueUndeliveredVoiceNotes(h.ctx, NOW);
    assert.equal(h.claims.length, 0, JSON.stringify(r.data));
    assert.equal(h.sent.length, 0);
  }
});

test('a receipt racing the claim wins: nothing is sent', async () => {
  const h = harness([row()], {}, { claim: () => false });
  await rescueUndeliveredVoiceNotes(h.ctx, NOW);
  assert.equal(h.sent.length, 0);
});

test('a revoked grant means no planner warning', async () => {
  const h = harness(
    [row({ scheduledInstantUtc: at(8), voiceRescuePushAt: at(-5) })],
    { 'friendships/planner_target/plannerGrants/planner_target': { granted: false } },
  );
  await rescueUndeliveredVoiceNotes(h.ctx, NOW);
  assert.equal(h.claims.length, 0);
  assert.equal(h.sent.length, 0);
});

test('per-run caps bound the work', async () => {
  const rows = Array.from({ length: 6 }, (_, i) =>
    row({}, { path: `scheduleItems/target/items/i${i}` }));
  const h = harness(rows);
  const summary = await rescueUndeliveredVoiceNotes(h.ctx, NOW, { maxPushes: 2, maxNotices: 1 });
  assert.equal(summary.pushes, 2);
});

test('the warning copy has fallbacks and no clock time', () => {
  const bare = buildVoiceUndeliveredMessage({ title: '', targetName: null, targetUid: 't', itemId: 'i' });
  assert.match(bare.notification.body, /^Your voice note hasn't reached Someone's phone yet/);
  assert.doesNotMatch(bare.notification.body, /\d/);
});

test('the rescue rides the 2-minute lapse cron, which left it budget', () => {
  const index = readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
  const lapseCron = index.slice(index.indexOf('async function runLapseCron'));
  assert.match(lapseCron.slice(0, 1200), /rescueUndeliveredVoiceNotes\(context, now\)/);
  assert.equal(MAX_SKIPS_PER_RUN, 2);
  assert.equal(MAX_REJECTS_PER_RUN, 6);
});
