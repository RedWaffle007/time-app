import assert from 'node:assert/strict';
import test from 'node:test';

import { buildMessage, sendEventNotification } from '../src/notify.js';

// R6 (2026-10-02): the target's optional note to the planner is its own push,
// "Note from {name}" + "About {task}: {note}", read from Firestore only.

const PAIR = 'planner_target';
const ITEM = 'scheduleItems/target/items/item-1';

function harness(item, extra = {}) {
  const docs = {
    [ITEM]: {
      targetUid: 'target', createdByUid: 'planner', groupId: '',
      status: 'approved', title: 'Walk', ...item,
    },
    [`friendships/${PAIR}`]: { participants: ['planner', 'target'] },
    'users/target': { name: 'Test Target' },
    ...extra,
  };
  const sent = [];
  const listed = [];
  const patched = [];
  return {
    sent, listed, patched,
    ctx: {
      db: {
        getDoc: async (path) => docs[path] ?? null,
        listDocIds: async (path) => { listed.push(path); return ['t1']; },
        deleteDoc: async () => {},
        patchDoc: async (path, fields) => patched.push({ path, fields }),
      },
      fcm: { send: async (_token, message) => { sent.push(message); return { ok: true }; } },
    },
  };
}

const send = (h) => sendEventNotification(h.ctx, {
  event: 'replied', targetUid: 'target', itemId: 'item-1',
});

test('a note reaches the PLANNER, naming the sender and the task', async () => {
  const h = harness({ reply: { text: '  Running 5 min late  ' } });
  const res = await send(h);
  assert.equal(res.sent, 1);
  assert.equal(res.recipientUid, 'planner');
  assert.deepEqual(h.listed, ['users/planner/fcmTokens']);
  assert.equal(h.sent[0].notification.title, 'Note from Test Target');
  assert.equal(h.sent[0].notification.body, 'About Walk: Running 5 min late');
  assert.equal(h.sent[0].data.event, 'replied');
  assert.equal(h.sent[0].data.uhOh, undefined, 'a note is not a negative event');
  assert.deepEqual(h.patched.at(-1).fields.notifiedReply, true);
});

test('a voice note reply says "your voice note", with no task name', () => {
  const msg = buildMessage('replied', null, {
    targetUid: 't', createdByUid: 'p', title: 'Voice alarm',
    voiceNote: { sha256: 'a'.repeat(64) }, reply: { text: 'Loved it' },
  }, 't', 'i', { actorName: 'Test Target', groupName: null });
  assert.equal(msg.notification.title, 'Note from Test Target');
  assert.equal(msg.notification.body, 'About your voice note: Loved it');
});

test('a group plan says which group, as its own push (not a summary list)', async () => {
  const h = harness(
    { groupId: 'g1', reply: { text: 'Done soon' }, alarm: { unavailableAt: '2030-01-01T00:00:00Z' } },
    { 'groups/g1': { name: 'Family', memberUids: ['planner', 'target'] } },
  );
  const res = await send(h);
  assert.equal(res.sent, 1);
  assert.equal(h.sent[0].notification.title, 'Note from Test Target in Family');
  assert.equal(h.sent[0].notification.body, 'About Walk: Done soon');
});

test('no note on the item: nothing is sent', async () => {
  for (const reply of [undefined, { text: '' }, { text: '   ' }, { text: 7 }]) {
    const h = harness(reply === undefined ? {} : { reply });
    const res = await send(h);
    assert.equal(res.sent, 0);
    assert.equal(res.reason, 'no-reply');
  }
});

test('sent once: a repeat is already-notified', async () => {
  const h = harness({ reply: { text: 'Hi' }, notifiedReply: true });
  const res = await send(h);
  assert.equal(res.reason, 'already-notified');
  assert.equal(h.sent.length, 0);
});

test('a self-plan never sends a note push', async () => {
  const h = harness({ createdByUid: 'target', reply: { text: 'Hi' } });
  assert.equal((await send(h)).reason, 'self-planned');
});

test('no friendship any more: no push', async () => {
  const h = harness({ reply: { text: 'Hi' } }, { [`friendships/${PAIR}`]: null });
  assert.equal((await send(h)).reason, 'no-active-grant');
});

test('only the target may report a note (the door\'s authz)', async () => {
  const { readFileSync } = await import('node:fs');
  const src = readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
  const planner = /const PLANNER_TRIGGERED = new Set\(\[([^\]]*)\]\)/.exec(src)[1];
  assert.ok(!planner.includes('replied'), 'replied is target-triggered');
});
