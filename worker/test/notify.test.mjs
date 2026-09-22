import assert from 'node:assert/strict';
import test from 'node:test';

import {
  buildMessage,
  sendEventNotification,
  sendFriendNotification,
} from '../src/notify.js';

function context(docs, {
  tokens = ['token-1'],
  tokenResults = {},
} = {}) {
  const sent = [];
  const sentTokens = [];
  const deleted = [];
  const patched = [];
  const listed = [];
  return {
    sent,
    sentTokens,
    deleted,
    patched,
    listed,
    ctx: {
      db: {
        getDoc: async (path) => docs[path] ?? null,
        listDocIds: async (path) => {
          listed.push(path);
          return tokens;
        },
        deleteDoc: async (path) => deleted.push(path),
        patchDoc: async (path, fields) => patched.push({ path, fields }),
      },
      fcm: {
        send: async (token, message) => {
          sentTokens.push(token);
          sent.push(message);
          return tokenResults[token] ?? { ok: true };
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

test('all ordinary item-event payloads keep their audience routing data', () => {
  const item = { title: 'Morning walk', status: 'approved', tier: 'normal' };
  const cases = [
    ['created', null, 'New plan for you', 'Morning walk'],
    ['withdrawn', null, 'Plan withdrawn', 'Morning walk'],
    ['decided', 'approved', 'Plan approved', 'Approved: Morning walk'],
    ['decided', 'rejected', 'Plan rejected', 'Rejected: Morning walk'],
    ['outcome', 'done', 'Task completed', 'Marked done: Morning walk'],
    ['outcome', 'skipped', 'Task skipped', 'Skipped: Morning walk'],
  ];

  for (const [event, subtype, title, body] of cases) {
    const message = buildMessage(event, subtype, item, 'target', 'item-1');
    assert.deepEqual(message.notification, { title, body });
    assert.deepEqual(message.data, {
      type: event === 'outcome' ? 'outcome' : event,
      event,
      targetUid: 'target',
      itemId: 'item-1',
      ...(subtype ? { subtype } : {}),
    });
  }
});

test('a group outcome notifies the planner and stamps only the outcome guard', async () => {
  const item = {
    targetUid: 'target',
    createdByUid: 'planner',
    groupId: 'group-1',
    title: 'Finish report',
    status: 'approved',
    outcome: { result: 'done' },
  };
  const harness = context({
    'scheduleItems/target/items/item-1': item,
    'groups/group-1/plannerGrants/planner_target': { granted: true },
  });

  const result = await sendEventNotification(harness.ctx, {
    event: 'outcome',
    targetUid: 'target',
    itemId: 'item-1',
  });

  assert.equal(result.recipientUid, 'planner');
  assert.deepEqual(harness.listed, ['users/planner/fcmTokens']);
  assert.equal(harness.sent[0].notification.title, 'Task completed');
  assert.equal(harness.patched.length, 1);
  assert.equal(harness.patched[0].path, 'scheduleItems/target/items/item-1');
  assert.equal(harness.patched[0].fields.notifiedOutcome, 'done');
  assert.equal(typeof harness.patched[0].fields.notifiedAt, 'string');
  assert.equal(harness.patched[0].fields.notifiedCreated, undefined);
});

test('created and withdrawn events notify the target, decisions notify the planner', async () => {
  const cases = [
    ['created', { status: 'pending' }, 'target', 'notifiedCreated', true],
    ['withdrawn', { status: 'withdrawn' }, 'target', 'notifiedWithdrawn', true],
    ['decided', { status: 'approved' }, 'planner', 'notifiedDecided', 'approved'],
  ];

  for (const [event, state, recipient, guard, value] of cases) {
    const item = {
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: 'group-1',
      title: 'Task',
      ...state,
    };
    const harness = context({
      'scheduleItems/target/items/item-1': item,
      'groups/group-1/plannerGrants/planner_target': { granted: true },
    });

    const result = await sendEventNotification(harness.ctx, {
      event,
      targetUid: 'target',
      itemId: 'item-1',
    });

    assert.equal(result.recipientUid, recipient);
    assert.deepEqual(harness.listed, [`users/${recipient}/fcmTokens`]);
    assert.equal(harness.patched[0].fields[guard], value);
  }
});

test('item events fail closed on malformed, missing, self-planned, or false state', async () => {
  const self = {
    targetUid: 'same',
    createdByUid: 'same',
    groupId: '',
    status: 'pending',
  };
  const undecided = {
    targetUid: 'target',
    createdByUid: 'planner',
    groupId: 'group-1',
    status: 'pending',
  };
  const docs = {
    'scheduleItems/same/items/self': self,
    'scheduleItems/target/items/undecided': undecided,
  };
  const harness = context(docs);

  assert.equal((await sendEventNotification(harness.ctx, {
    event: 'unknown', targetUid: 'target', itemId: 'x',
  })).reason, 'bad-args');
  assert.equal((await sendEventNotification(harness.ctx, {
    event: 'created', targetUid: 'target', itemId: 'missing',
  })).reason, 'item-not-found');
  assert.equal((await sendEventNotification(harness.ctx, {
    event: 'created', targetUid: 'same', itemId: 'self',
  })).reason, 'self-planned');
  assert.equal((await sendEventNotification(harness.ctx, {
    event: 'decided', targetUid: 'target', itemId: 'undecided',
  })).reason, 'not-decided');
  assert.equal((await sendEventNotification(harness.ctx, {
    event: 'outcome', targetUid: 'target', itemId: 'undecided',
  })).reason, 'outcome-not-recorded');
  assert.equal(harness.sent.length, 0);
  assert.equal(harness.patched.length, 0);
});

test('an event already delivered is neither resent nor restamped', async () => {
  const harness = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: 'group-1',
      status: 'approved',
      notifiedDecided: 'approved',
    },
  });

  const result = await sendEventNotification(harness.ctx, {
    event: 'decided', targetUid: 'target', itemId: 'item-1',
  });

  assert.equal(result.reason, 'already-notified');
  assert.equal(harness.sent.length, 0);
  assert.equal(harness.patched.length, 0);
});

test('no token is a normal no-send and leaves the event retryable', async () => {
  const harness = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target', createdByUid: 'planner', groupId: 'group-1', status: 'pending',
    },
    'groups/group-1/plannerGrants/planner_target': { granted: true },
  }, { tokens: [] });

  const result = await sendEventNotification(harness.ctx, {
    event: 'created', targetUid: 'target', itemId: 'item-1',
  });

  assert.equal(result.reason, 'no-tokens');
  assert.equal(harness.sent.length, 0);
  assert.equal(harness.patched.length, 0);
});

test('multi-device sends clean bad tokens and stamp after one real delivery', async () => {
  const tokens = ['good', 'gone', 'invalid', 'transient'];
  const harness = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target', createdByUid: 'planner', groupId: 'group-1', status: 'pending',
    },
    'groups/group-1/plannerGrants/planner_target': { granted: true },
  }, {
    tokens,
    tokenResults: {
      gone: { error: 'UNREGISTERED' },
      invalid: { error: 'INVALID' },
      transient: { error: 'OTHER' },
    },
  });

  const result = await sendEventNotification(harness.ctx, {
    event: 'created', targetUid: 'target', itemId: 'item-1',
  });

  assert.deepEqual(harness.sentTokens, tokens);
  assert.equal(result.sent, 1);
  assert.equal(result.cleaned, 2);
  assert.deepEqual(harness.deleted, [
    'users/target/fcmTokens/gone',
    'users/target/fcmTokens/invalid',
  ]);
  assert.equal(harness.patched.length, 1);
});

test('all failed device sends leave the event unstamped for a later retry', async () => {
  const harness = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target', createdByUid: 'planner', groupId: 'group-1', status: 'pending',
    },
    'groups/group-1/plannerGrants/planner_target': { granted: true },
  }, {
    tokens: ['transient'],
    tokenResults: { transient: { error: 'OTHER' } },
  });

  const result = await sendEventNotification(harness.ctx, {
    event: 'created', targetUid: 'target', itemId: 'item-1',
  });

  assert.equal(result.reason, 'no-delivery');
  assert.equal(harness.patched.length, 0);
  assert.equal(harness.deleted.length, 0);
});

test('friend and planning notifications preserve actor, recipient, and kind', async () => {
  const cases = [
    ['friendRequest', undefined, 'sender', 'recipient', 'New friend request'],
    ['friendAccept', undefined, 'recipient', 'sender', 'Friend request accepted'],
    ['planningRequest', 'normal', 'sender', 'recipient', 'Planning request'],
    ['planningRequest', 'emergency', 'sender', 'recipient', 'Emergency planning request'],
    ['planningApprove', 'normal', 'recipient', 'sender', 'Planning approved'],
    ['planningApprove', 'emergency', 'recipient', 'sender', 'Emergency planning approved'],
  ];

  for (const [event, kind, actor, recipient, title] of cases) {
    const harness = context({ [`users/${actor}`]: { name: 'Alex' } });
    const result = await sendFriendNotification(harness.ctx, {
      event, fromUid: 'sender', toUid: 'recipient', kind,
    });

    assert.equal(result.recipientUid, recipient);
    assert.deepEqual(harness.listed, [`users/${recipient}/fcmTokens`]);
    assert.equal(harness.sent[0].notification.title, title);
    assert.equal(harness.sent[0].notification.body.startsWith('Alex'), true);
    assert.deepEqual(harness.sent[0].data, {
      type: event,
      event,
      fromUid: 'sender',
      toUid: 'recipient',
      ...(kind ? { kind } : {}),
    });
  }
});

test('friend notifications reject bad parties and use a safe missing-name fallback', async () => {
  const invalid = context({});
  const bad = await sendFriendNotification(invalid.ctx, {
    event: 'friendRequest', fromUid: 'same', toUid: 'same',
  });
  assert.equal(bad.reason, 'bad-args');
  assert.equal(invalid.sent.length, 0);

  const fallback = context({});
  await sendFriendNotification(fallback.ctx, {
    event: 'friendRequest', fromUid: 'sender', toUid: 'recipient',
  });
  assert.equal(
    fallback.sent[0].notification.body,
    'Someone sent you a friend request',
  );
});

test('friend notifications share multi-device cleanup semantics', async () => {
  const harness = context({ 'users/sender': { name: 'Alex' } }, {
    tokens: ['good', 'gone', 'transient'],
    tokenResults: {
      gone: { error: 'UNREGISTERED' },
      transient: { error: 'OTHER' },
    },
  });

  const result = await sendFriendNotification(harness.ctx, {
    event: 'friendRequest', fromUid: 'sender', toUid: 'recipient',
  });

  assert.equal(result.sent, 1);
  assert.equal(result.cleaned, 1);
  assert.deepEqual(harness.deleted, ['users/recipient/fcmTokens/gone']);
});
