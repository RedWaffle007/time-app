import assert from 'node:assert/strict';
import test from 'node:test';

import { buildMessage, sendEventNotification } from '../src/notify.js';

function context(docs) {
  const sent = [];
  return {
    sent,
    ctx: {
      db: {
        getDoc: async (path) => docs[path] ?? null,
        listDocIds: async () => ['token-1'],
        deleteDoc: async () => {},
        patchDoc: async () => {},
      },
      fcm: {
        send: async (_token, message) => {
          sent.push(message);
          return { ok: true };
        },
      },
    },
  };
}

test('normal friendship plans authorize through plannerGrants with empty groupId', async () => {
  const item = {
    targetUid: 'target',
    createdByUid: 'planner',
    groupId: '',
    title: 'Call home',
    status: 'pending',
    tier: 'normal',
  };
  const { ctx, sent } = context({
    'scheduleItems/target/items/item-1': item,
    'friendships/planner_target/plannerGrants/planner_target': {
      granted: true,
    },
  });

  const result = await sendEventNotification(ctx, {
    event: 'created',
    targetUid: 'target',
    itemId: 'item-1',
  });

  assert.equal(result.sent, 1);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].notification.title, 'New plan for you');
});

test('emergency friendship plans authorize separately and carry an alarm command', async () => {
  const fireAtUtc = '2030-01-02T03:04:05.000Z';
  const item = {
    targetUid: 'target',
    createdByUid: 'planner',
    groupId: '',
    title: 'Take medicine',
    note: 'With water',
    scheduledInstantUtc: fireAtUtc,
    status: 'approved',
    tier: 'emergency',
  };
  const { ctx, sent } = context({
    'scheduleItems/target/items/item-2': item,
    'friendships/planner_target/emergencyGrants/planner_target': {
      granted: true,
    },
  });

  const result = await sendEventNotification(ctx, {
    event: 'created',
    targetUid: 'target',
    itemId: 'item-2',
  });

  assert.equal(result.sent, 1);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].notification, undefined);
  assert.equal(sent[0].android.priority, 'high');
  assert.deepEqual(sent[0].data, {
    type: 'created',
    event: 'created',
    targetUid: 'target',
    itemId: 'item-2',
    command: 'scheduleReminder',
    fireAtUtc,
    title: 'Take medicine',
    body: 'With water',
    pushTitle: 'New emergency plan for you',
    pushBody: 'Take medicine',
  });
});

test('a normal friendship grant cannot authorize an emergency item', async () => {
  const item = {
    targetUid: 'target',
    createdByUid: 'planner',
    groupId: '',
    title: 'Take medicine',
    scheduledInstantUtc: '2030-01-02T03:04:05.000Z',
    status: 'approved',
    tier: 'emergency',
  };
  const { ctx, sent } = context({
    'scheduleItems/target/items/item-3': item,
    'friendships/planner_target/plannerGrants/planner_target': {
      granted: true,
    },
  });

  const result = await sendEventNotification(ctx, {
    event: 'created',
    targetUid: 'target',
    itemId: 'item-3',
  });

  assert.equal(result.reason, 'no-active-grant');
  assert.equal(sent.length, 0);
});

test('only approved emergency creates become background alarm commands', () => {
  const base = {
    title: 'Task',
    note: '',
    scheduledInstantUtc: '2030-01-02T03:04:05.000Z',
  };
  const normal = buildMessage(
    'created',
    null,
    { ...base, status: 'pending', tier: 'normal' },
    'target',
    'normal',
  );
  const emergency = buildMessage(
    'created',
    null,
    { ...base, status: 'approved', tier: 'emergency' },
    'target',
    'emergency',
  );

  assert.equal(normal.data.command, undefined);
  assert.equal(normal.notification.title, 'New plan for you');
  assert.equal(emergency.data.command, 'scheduleReminder');
  assert.equal(emergency.notification, undefined);
});
