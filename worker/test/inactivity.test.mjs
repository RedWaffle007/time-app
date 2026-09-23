import assert from 'node:assert/strict';
import test from 'node:test';

import {
  buildInactivityMessage,
  INACTIVITY_DELAY_MS,
  INACTIVITY_MESSAGES,
  sendDueInactivityNotifications,
} from '../src/inactivity.js';

function harness(states, { tokens = ['token-1'], tokenResults = {} } = {}) {
  const docs = Object.fromEntries(states.map((row) => [
    `inactivityStates/${row.id}`,
    { ...row.data },
  ]));
  const sent = [];
  const patched = [];
  const deleted = [];
  return {
    docs,
    sent,
    patched,
    deleted,
    ctx: {
      db: {
        listDueInactivityStates: async () => states,
        patchDocIfUnchanged: async (path, fields) => {
          patched.push({ path, fields, conditional: true });
          Object.assign(docs[path], fields);
          return true;
        },
        getDoc: async (path) => docs[path] ?? null,
        patchDoc: async (path, fields) => {
          patched.push({ path, fields, conditional: false });
          Object.assign(docs[path], fields);
        },
        listDocIds: async () => tokens,
        deleteDoc: async (path) => deleted.push(path),
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

const now = new Date('2026-09-23T12:00:00.000Z');
const dueState = (overrides = {}) => ({
  id: 'alice',
  updateTime: '2026-09-23T11:59:00.000Z',
  data: {
    uid: 'alice',
    lastActivityAt: new Date(now.getTime() - INACTIVITY_DELAY_MS).toISOString(),
    nextNotificationAt: now.toISOString(),
    sequenceIndex: 0,
    ...overrides,
  },
});

test('the copy bank has fifty short, distinct variants', () => {
  assert.equal(INACTIVITY_MESSAGES.length, 50);
  assert.equal(new Set(INACTIVITY_MESSAGES).size, 50);
  assert.equal(INACTIVITY_MESSAGES.every((copy) => copy.length <= 60), true);
});

test('a due state is leased, delivered, advanced, and scheduled six hours on', async () => {
  const h = harness([dueState({ sequenceIndex: 49 })]);
  const result = await sendDueInactivityNotifications(h.ctx, now);

  assert.equal(result.claimed, 1);
  assert.equal(result.sent, 1);
  assert.equal(h.sent[0].message.notification.body, INACTIVITY_MESSAGES[49]);
  assert.deepEqual(h.sent[0].message.data, {
    type: 'inactivity', event: 'inactivity',
  });
  const final = h.patched.at(-1).fields;
  assert.equal(final.sequenceIndex, 0);
  assert.equal(final.nextNotificationAt.toISOString(), '2026-09-23T18:00:00.000Z');
});

test('no delivery leaves the sequence cursor unchanged', async () => {
  const h = harness([dueState({ sequenceIndex: 12 })], { tokens: [] });
  await sendDueInactivityNotifications(h.ctx, now);

  assert.equal(h.sent.length, 0);
  assert.equal(h.patched.at(-1).fields.sequenceIndex, undefined);
});

test('an active lease or a lost conditional claim suppresses duplicates', async () => {
  const leased = harness([dueState({
    leaseUntil: new Date(now.getTime() + 60_000).toISOString(),
  })]);
  await sendDueInactivityNotifications(leased.ctx, now);
  assert.equal(leased.sent.length, 0);
  assert.equal(leased.patched.length, 0);

  const lost = harness([dueState()]);
  lost.ctx.db.patchDocIfUnchanged = async () => false;
  await sendDueInactivityNotifications(lost.ctx, now);
  assert.equal(lost.sent.length, 0);
});

test('activity racing a claimed notification wins and clears the lease', async () => {
  const h = harness([dueState()]);
  const originalClaim = h.ctx.db.patchDocIfUnchanged;
  h.ctx.db.patchDocIfUnchanged = async (...args) => {
    const claimed = await originalClaim(...args);
    h.ctx.db.getDoc = async () => ({
      uid: 'alice',
      lastActivityAt: new Date(now.getTime() - 60_000).toISOString(),
    });
    return claimed;
  };
  await sendDueInactivityNotifications(h.ctx, now);

  assert.equal(h.sent.length, 0);
  assert.equal(h.patched.at(-1).fields.leaseUntil, null);
});

test('activity while FCM is sending remains the final timer anchor', async () => {
  const h = harness([dueState()]);
  const freshActivity = new Date(now.getTime() + 30_000);
  h.ctx.fcm.send = async (token, message) => {
    h.sent.push({ token, message });
    h.docs['inactivityStates/alice'].lastActivityAt = freshActivity.toISOString();
    return { ok: true };
  };
  await sendDueInactivityNotifications(h.ctx, now);

  assert.equal(
    h.patched.at(-1).fields.nextNotificationAt.toISOString(),
    new Date(freshActivity.getTime() + INACTIVITY_DELAY_MS).toISOString(),
  );
});

test('bad tokens are cleaned while one successful device advances the cursor', async () => {
  const h = harness([dueState()], {
    tokens: ['good', 'gone', 'transient'],
    tokenResults: {
      gone: { error: 'UNREGISTERED' },
      transient: { error: 'OTHER' },
    },
  });
  const result = await sendDueInactivityNotifications(h.ctx, now);

  assert.equal(result.sent, 1);
  assert.equal(result.cleaned, 1);
  assert.deepEqual(h.deleted, ['users/alice/fcmTokens/gone']);
  assert.equal(h.patched.at(-1).fields.sequenceIndex, 1);
});

test('message construction uses the requested sequence entry', () => {
  assert.equal(
    buildInactivityMessage(3).notification.body,
    INACTIVITY_MESSAGES[3],
  );
});
