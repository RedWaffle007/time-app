import assert from 'node:assert/strict';
import test from 'node:test';

import {
  ACTIVITY_CHANNEL_ID,
  alarmHeadline,
  buildMessage,
  groupAdminUids,
  hasActiveItemGrant,
  outcomeTiming,
  sendEventNotification,
  sendFriendNotification,
} from '../src/notify.js';

function context(rawDocs, {
  tokens = ['token-1'],
  tokenResults = {},
} = {}) {
  // Friendship is the permission (2026-09-27). Older tests seed a retired
  // friendship grant doc to mean "these two are friends", so seed the
  // friendship itself wherever one appears; the grant doc is ignored.
  const docs = { ...rawDocs };
  for (const key of Object.keys(rawDocs)) {
    const m = /^friendships\/([^/]+)\/(plannerGrants|emergencyGrants)\//.exec(key);
    if (m && !(`friendships/${m[1]}` in docs)) docs[`friendships/${m[1]}`] = { participants: [] };
    // Item 3: group plans are authorised by MEMBERSHIP. Older tests seed a
    // retired group grant to mean "these two share the group", so add both
    // to that group's roster (a granted:false grant adds nobody).
    const g = /^groups\/([^/]+)\/plannerGrants\/([^_]+)_(.+)$/.exec(key);
    if (g && rawDocs[key] && rawDocs[key].granted === true) {
      const path = `groups/${g[1]}`;
      const current = docs[path] || {};
      const members = new Set(current.memberUids || []);
      members.add(g[2]);
      members.add(g[3]);
      docs[path] = { ...current, memberUids: [...members] };
    }
  }
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
        // Field-path upsert, like Firestore: deep-merge the written maps.
        patchPaths: async (path, fields) => {
          const merge = (a, b) => {
            const out = { ...(a || {}) };
            for (const [k, v] of Object.entries(b)) {
              out[k] = v && typeof v === 'object' && !Array.isArray(v)
                ? merge(out[k], v)
                : v;
            }
            return out;
          };
          docs[path] = merge(docs[path], fields);
        },
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

test('a friend\'s plan (empty groupId) is authorized by the friendship', async () => {
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

test('an alarm set through the (merged) emergency grant carries the alarm command', async () => {
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
    title: 'Someone planned Take medicine for you',
    body: 'With water',
    pushTitle: 'New alarm for you',
    pushBody: 'Someone set Take medicine for you',
  });
});

test('a voice alarm is announced as sent, with no task name (F4)', () => {
  const message = buildMessage(
    'created',
    null,
    {
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: '',
      title: 'Voice alarm',
      status: 'approved',
      scheduledInstantUtc: '2030-01-02T03:04:05.000Z',
      voiceNote: { sha256: 'a'.repeat(64), sizeBytes: 900, durationMs: 7000 },
    },
    'target',
    'item-v',
    { actorName: 'Test Planner' },
  );
  assert.equal(message.data.pushTitle, 'New alarm for you');
  assert.equal(message.data.pushBody, 'Test Planner sent you a voice alarm');
});

// F2: one permission — the normal friendship grant now authorises any alarm,
// including a legacy emergency-tier one.
test('a normal friendship grant authorises an emergency-tier item too', async () => {
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

  assert.equal(result.reason, 'sent');
  assert.equal(sent[0].data.command, 'scheduleReminder');
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
  // `created` here is a LEGACY pending plan (an approved one is an alarm
  // command — see the F2 tests); withdrawn is the planner's Cancel.
  const item = { title: 'Morning walk', status: 'pending', tier: 'normal' };
  const cases = [
    ['created', null, 'New plan for you', 'Test Person planned Morning walk for you'],
    ['withdrawn', null, 'Alarm cancelled', 'Test Person cancelled: Morning walk'],
    ['decided', 'approved', 'Plan approved', 'Test Person approved: Morning walk'],
    ['decided', 'rejected', 'Plan rejected', 'Test Person rejected: Morning walk'],
    ['outcome', 'done', 'Task completed', 'Test Person completed the task: Morning walk'],
    ['outcome', 'skipped', 'Task skipped', 'Test Person skipped task: Morning walk'],
  ];

  for (const [event, subtype, title, body] of cases) {
    const message = buildMessage(event, subtype, item, 'target', 'item-1', {
      actorName: 'Test Person',
      groupName: null,
    });
    assert.deepEqual(message.notification, { title, body });
    assert.deepEqual(message.android, {
      priority: 'high',
      notification: { channel_id: ACTIVITY_CHANNEL_ID },
    });
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
  assert.equal(harness.sent[0].notification.title, 'Group task completed');
  assert.equal(harness.patched.length, 1);
  assert.equal(harness.patched[0].path, 'scheduleItems/target/items/item-1');
  assert.equal(harness.patched[0].fields.notifiedOutcome, 'done');
  assert.equal(typeof harness.patched[0].fields.notifiedAt, 'string');
  assert.equal(harness.patched[0].fields.notifiedCreated, undefined);
});

test('a missed alarm corrected to done sends an explicit late follow-up', () => {
  const message = buildMessage('outcome', 'done', {
    title: 'Morning walk',
    alarm: { unavailableAt: '2026-09-24T09:01:00Z' },
  }, 'target', 'item-1');

  assert.deepEqual(message.notification, {
    title: 'Task completed late',
    body: 'Someone completed the task after a missed alarm: Morning walk',
  });
});

test('skipped notification guard does not suppress the later done follow-up', async () => {
  // Since 2026-09-28 a GROUP member's missed-popup Done joins the live
  // "Done" list rather than its own push; the guard behaviour is unchanged.
  const harness = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: 'group-1',
      title: 'Morning walk',
      status: 'approved',
      scheduledInstantUtc: '2026-09-24T09:00:00Z',
      alarm: { unavailableAt: '2026-09-24T09:01:00Z' },
      outcome: { result: 'done' },
      notifiedOutcome: 'skipped',
    },
    'groups/group-1/plannerGrants/planner_target': { granted: true },
  });

  const result = await sendEventNotification(harness.ctx, {
    event: 'outcome',
    targetUid: 'target',
    itemId: 'item-1',
  });

  assert.equal(result.reason, 'sent');
  assert.equal(harness.sent[0].notification.title, 'Done "Morning walk"');
  assert.equal(harness.patched[0].fields.notifiedOutcome, 'done');
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

test('friend notifications preserve actor and recipient', async () => {
  const cases = [
    ['friendRequest', undefined, 'sender', 'recipient', 'New friend request'],
    ['friendAccept', undefined, 'recipient', 'sender', 'Friend request accepted'],
  ];

  for (const [event, kind, actor, recipient, title] of cases) {
    const harness = context({ [`users/${actor}`]: { name: 'Test Person' } });
    const result = await sendFriendNotification(harness.ctx, {
      event, fromUid: 'sender', toUid: 'recipient', kind,
    });

    assert.equal(result.recipientUid, recipient);
    assert.deepEqual(harness.listed, [`users/${recipient}/fcmTokens`]);
    assert.equal(harness.sent[0].notification.title, title);
    assert.equal(harness.sent[0].notification.body.startsWith('Test Person'), true);
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

test('plan-request notification carries the request id for routing', async () => {
  const harness = context({
    'users/requester': { name: 'Test Person' },
    'planRequests/batch_planner': { status: 'pending' },
  });
  const result = await sendFriendNotification(harness.ctx, {
    event: 'planRequested',
    fromUid: 'requester',
    toUid: 'planner',
    planRequestId: 'batch_planner',
  });

  assert.equal(result.recipientUid, 'planner');
  assert.deepEqual(harness.sent[0].data, {
    type: 'planRequested',
    event: 'planRequested',
    fromUid: 'requester',
    toUid: 'planner',
    planRequestId: 'batch_planner',
  });
  assert.equal(harness.patched[0].path, 'planRequests/batch_planner');
  assert.equal(harness.patched[0].fields.notifiedRequested, true);
});

test('plan-request notification replay is deduplicated', async () => {
  const harness = context({
    'planRequests/batch_planner': { notifiedRequested: true },
  });
  const result = await sendFriendNotification(harness.ctx, {
    event: 'planRequested',
    fromUid: 'requester',
    toUid: 'planner',
    planRequestId: 'batch_planner',
  });

  assert.equal(result.reason, 'already-notified');
  assert.equal(harness.sent.length, 0);
});

test('friend notifications share multi-device cleanup semantics', async () => {
  const harness = context({ 'users/sender': { name: 'Test Person' } }, {
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

test('outcome timing is derived from Firestore timestamps only', () => {
  const due = '2030-01-01T10:00:00.000Z';
  const early = '2030-01-01T09:30:00.000Z';
  const after = '2030-01-01T10:05:00.000Z';
  const item = (outcome, extra = {}) => ({ scheduledInstantUtc: due, outcome, ...extra });

  assert.equal(outcomeTiming('done', item({ completedAt: early })), 'early');
  assert.equal(outcomeTiming('done', item({ completedAt: after })), 'onTime');
  assert.equal(outcomeTiming('done', item({ completedAt: due })), 'onTime');
  assert.equal(outcomeTiming('skipped', item({ skippedAt: early })), 'early');
  assert.equal(outcomeTiming('skipped', item({ skippedAt: after })), 'onTime');
  // A skip's timing never reads completedAt, and vice versa.
  assert.equal(outcomeTiming('skipped', item({ completedAt: early })), 'onTime');
  assert.equal(outcomeTiming('done', item({ skippedAt: early })), 'onTime');
  // Missing / unparsable timestamps are never guessed as early.
  assert.equal(outcomeTiming('done', item({})), 'onTime');
  assert.equal(outcomeTiming('done', { outcome: { completedAt: early } }), 'onTime');
  // A missed alarm answered Done is late even if the clocks disagree.
  assert.equal(
    outcomeTiming('done', item({ completedAt: early }, {
      alarm: { unavailableAt: '2030-01-01T10:01:00.000Z' },
    })),
    'late',
  );
});

test('early done and early skip use the before-time copy, friendship and group', () => {
  const base = {
    title: 'Morning walk',
    scheduledInstantUtc: '2030-01-01T10:00:00.000Z',
  };
  const done = { ...base, outcome: { result: 'done', completedAt: '2030-01-01T09:00:00Z' } };
  const skipped = { ...base, outcome: { result: 'skipped', skippedAt: '2030-01-01T09:00:00Z' } };
  const friend = { actorName: 'Test Person', groupName: null };
  const group = { actorName: 'Test Person', groupName: 'Book club' };

  assert.deepEqual(buildMessage('outcome', 'done', done, 't', 'i', friend).notification, {
    title: 'Task completed early',
    body: 'Test Person completed Task: Morning walk before time',
  });
  assert.deepEqual(buildMessage('outcome', 'skipped', skipped, 't', 'i', friend).notification, {
    title: 'Task skipped early',
    body: 'Test Person skipped Task: Morning walk before time',
  });
  assert.deepEqual(buildMessage('outcome', 'done', done, 't', 'i', group).notification, {
    title: 'Group task completed early',
    body: 'Test Person completed Task: Morning walk before time in Book club',
  });
  assert.deepEqual(buildMessage('outcome', 'skipped', skipped, 't', 'i', group).notification, {
    title: 'Group task skipped early',
    body: 'Test Person skipped Task: Morning walk before time in Book club',
  });
});

test('a done outcome never renders skipped copy and vice versa', () => {
  const item = { title: 'Walk', scheduledInstantUtc: '2000-01-01T00:00:00Z' };
  for (const names of [{}, { actorName: 'Test Person', groupName: 'G' }]) {
    const done = buildMessage('outcome', 'done', item, 't', 'i', names).notification;
    const skip = buildMessage('outcome', 'skipped', item, 't', 'i', names).notification;
    assert.match(done.title, /completed/);
    assert.doesNotMatch(`${done.title} ${done.body}`, /skip/i);
    assert.match(skip.title, /skipped/);
    assert.doesNotMatch(`${skip.title} ${skip.body}`, /complet/i);
  }
});

test('group plans are labelled on every event, named or not', () => {
  const item = { title: 'Standup', status: 'pending' };
  const cases = [
    ['created', null, 'New group plan for you'],
    ['withdrawn', null, 'Group alarm cancelled'],
    ['decided', 'approved', 'Group plan approved'],
    ['decided', 'rejected', 'Group plan rejected'],
    ['outcome', 'done', 'Group task completed'],
    ['outcome', 'skipped', 'Group task skipped'],
  ];
  for (const [event, subtype, title] of cases) {
    const named = buildMessage(event, subtype, item, 't', 'i', {
      actorName: 'Test Person', groupName: 'Team',
    }).notification;
    assert.equal(named.title, title);
    assert.match(named.body, / in Team$/);
    // A group whose name is missing is still labelled a group in the title.
    const unnamed = buildMessage(event, subtype, item, 't', 'i', {
      actorName: 'Test Person', groupName: '',
    }).notification;
    assert.equal(unnamed.title, title);
    assert.doesNotMatch(unnamed.body, / in /);
  }
});

test('a new group alarm keeps the alarm command and says group', () => {
  const message = buildMessage('created', null, {
    title: 'Evacuate',
    status: 'approved',
    tier: 'emergency',
    scheduledInstantUtc: '2030-01-01T10:00:00.000Z',
  }, 't', 'i', { actorName: 'Test Person', groupName: 'Family' });
  assert.equal(message.data.command, 'scheduleReminder');
  assert.equal(message.data.title, 'Test Person planned Evacuate for you');
  assert.equal(message.data.pushTitle, 'New group alarm for you');
  assert.equal(message.data.pushBody, 'Test Person set Evacuate for you in Family');
});

test('the actor name and group name are read from Firestore per event', async () => {
  const cases = [
    ['created', { status: 'pending' }, 'Planner Person'],
    ['withdrawn', { status: 'withdrawn' }, 'Planner Person'],
    ['decided', { status: 'approved' }, 'Target Person'],
    ['outcome', { status: 'approved', outcome: { result: 'done' } }, 'Target Person'],
  ];
  for (const [event, state, actor] of cases) {
    const harness = context({
      'scheduleItems/target/items/item-1': {
        targetUid: 'target',
        createdByUid: 'planner',
        groupId: 'group-1',
        title: 'Task',
        ...state,
      },
      'groups/group-1/plannerGrants/planner_target': { granted: true },
      'groups/group-1': { name: 'Team' },
      'users/planner': { name: 'Planner Person' },
      'users/target': { name: 'Target Person' },
    });
    await sendEventNotification(harness.ctx, {
      event, targetUid: 'target', itemId: 'item-1',
    });
    assert.equal(harness.sent[0].notification.body.startsWith(actor), true, event);
    assert.equal(harness.sent[0].notification.body.endsWith(' in Team'), true, event);
  }
});

test('friendship plans never read a group and are not labelled group', async () => {
  const reads = [];
  const harness = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: '',
      title: 'Walk',
      status: 'approved',
      outcome: { result: 'skipped' },
    },
    'friendships/planner_target/plannerGrants/planner_target': { granted: true },
    'users/target': { name: 'Target Person' },
  });
  const getDoc = harness.ctx.db.getDoc;
  harness.ctx.db.getDoc = async (path) => {
    reads.push(path);
    return getDoc(path);
  };
  await sendEventNotification(harness.ctx, {
    event: 'outcome', targetUid: 'target', itemId: 'item-1',
  });
  assert.equal(reads.some((path) => path.startsWith('groups/')), false);
  assert.deepEqual(harness.sent[0].notification, {
    title: 'Task skipped',
    body: 'Target Person skipped task: Walk',
  });
});

test('friend-graph pushes use the activity channel at high priority', async () => {
  const harness = context({ 'users/sender': { name: 'Test Person' } });
  await sendFriendNotification(harness.ctx, {
    event: 'friendRequest', fromUid: 'sender', toUid: 'recipient',
  });
  assert.deepEqual(harness.sent[0].android, {
    priority: 'high',
    notification: { channel_id: ACTIVITY_CHANNEL_ID },
  });
});

function dismissedItem(extra = {}) {
  return {
    targetUid: 'target',
    createdByUid: 'planner',
    groupId: '',
    title: 'Morning walk',
    status: 'approved',
    alarm: { rangAt: '2030-01-01T10:00:00Z', dismissedAt: '2030-01-01T10:00:20Z' },
    ...extra,
  };
}

test('a recorded dismissal notifies the planner, named, once', async () => {
  const harness = context({
    'scheduleItems/target/items/item-1': dismissedItem(),
    'friendships/planner_target/plannerGrants/planner_target': { granted: true },
    'users/target': { name: 'Target Person' },
  });

  const result = await sendEventNotification(harness.ctx, {
    event: 'dismissed', targetUid: 'target', itemId: 'item-1',
  });

  assert.equal(result.recipientUid, 'planner');
  assert.deepEqual(harness.listed, ['users/planner/fcmTokens']);
  assert.deepEqual(harness.sent[0].notification, {
    title: 'Alarm dismissed',
    body: 'Target Person dismissed the alarm for Morning walk',
  });
  assert.equal(harness.sent[0].data.event, 'dismissed');
  assert.equal(harness.patched[0].fields.notifiedDismissed, true);
  // Its own guard: it never suppresses the later outcome push.
  assert.equal(harness.patched[0].fields.notifiedOutcome, undefined);
});

test('dismissed fails closed without a recorded dismissal, and dedups', async () => {
  const harness = context({
    'scheduleItems/target/items/none': dismissedItem({ alarm: { rangAt: '2030-01-01T10:00:00Z' } }),
    'scheduleItems/target/items/noalarm': dismissedItem({ alarm: undefined }),
    'scheduleItems/target/items/done': dismissedItem({ notifiedDismissed: true }),
    'friendships/planner_target/plannerGrants/planner_target': { granted: true },
  });
  for (const [itemId, reason] of [
    ['none', 'not-dismissed'],
    ['noalarm', 'not-dismissed'],
    ['done', 'already-notified'],
  ]) {
    const result = await sendEventNotification(harness.ctx, {
      event: 'dismissed', targetUid: 'target', itemId,
    });
    assert.equal(result.reason, reason, itemId);
  }
  assert.equal(harness.sent.length, 0);
  assert.equal(harness.patched.length, 0);
});

test('a self-planned dismissal notifies nobody', async () => {
  const harness = context({
    'scheduleItems/me/items/item-1': dismissedItem({ targetUid: 'me', createdByUid: 'me' }),
  });
  const result = await sendEventNotification(harness.ctx, {
    event: 'dismissed', targetUid: 'me', itemId: 'item-1',
  });
  assert.equal(result.reason, 'self-planned');
  assert.equal(harness.sent.length, 0);
});

test('a group dismissal is labelled a group alarm', () => {
  const message = buildMessage('dismissed', null, dismissedItem(), 't', 'i', {
    actorName: 'Test Person', groupName: 'Team',
  });
  assert.deepEqual(message.notification, {
    title: 'Group alarm dismissed',
    body: 'Test Person dismissed the alarm for Morning walk in Team',
  });
});

function joinDocs(requestExtra = {}, groupExtra = {}) {
  return {
    'groups/group-1/joinRequests/candidate': {
      candidateUid: 'candidate',
      status: 'approved',
      source: 'code',
      ...requestExtra,
    },
    'groups/group-1': {
      name: 'Book club',
      memberUids: ['owner', 'member', 'candidate'],
      ...groupExtra,
    },
    'users/member': { name: 'Test Person' },
  };
}

test('an approved code join notifies the candidate once and stamps the request', async () => {
  const harness = context(joinDocs());
  const result = await sendFriendNotification(harness.ctx, {
    event: 'groupJoinApproved', fromUid: 'member', toUid: 'candidate', groupId: 'group-1',
  });

  assert.equal(result.recipientUid, 'candidate');
  assert.deepEqual(harness.listed, ['users/candidate/fcmTokens']);
  assert.deepEqual(harness.sent[0].notification, {
    title: 'Group join approved',
    body: 'Your request to join Book club was approved',
  });
  assert.deepEqual(harness.sent[0].data, {
    type: 'groupJoinApproved',
    event: 'groupJoinApproved',
    fromUid: 'member',
    toUid: 'candidate',
    groupId: 'group-1',
  });
  assert.equal(harness.patched[0].path, 'groups/group-1/joinRequests/candidate');
  assert.equal(harness.patched[0].fields.notifiedApproved, true);
});

test('a friend invitation reads as being added', async () => {
  const harness = context(joinDocs({ source: 'friend' }));
  await sendFriendNotification(harness.ctx, {
    event: 'groupJoinApproved', fromUid: 'member', toUid: 'candidate', groupId: 'group-1',
  });
  assert.deepEqual(harness.sent[0].notification, {
    title: 'Added to a group',
    body: "You're now a member of Book club",
  });
});

test('group-join pushes fail closed on unapproved, non-member, missing or replayed', async () => {
  const cases = [
    [joinDocs({ status: 'pending' }), 'not-approved'],
    [joinDocs({ status: 'rejected' }), 'not-approved'],
    [joinDocs({}, { memberUids: ['owner', 'member'] }), 'not-member'],
    [joinDocs({ notifiedApproved: true }), 'already-notified'],
    [{}, 'request-not-found'],
  ];
  for (const [docs, reason] of cases) {
    const harness = context(docs);
    const result = await sendFriendNotification(harness.ctx, {
      event: 'groupJoinApproved', fromUid: 'member', toUid: 'candidate', groupId: 'group-1',
    });
    assert.equal(result.reason, reason);
    assert.equal(harness.sent.length, 0);
    assert.equal(harness.patched.length, 0);
  }
  const noGroup = context(joinDocs());
  assert.equal((await sendFriendNotification(noGroup.ctx, {
    event: 'groupJoinApproved', fromUid: 'member', toUid: 'candidate',
  })).reason, 'bad-args');
});

test('created delivery matrix: friendship, group and emergency reach the target', async () => {
  const future = '2030-01-01T10:00:00.000Z';
  const cases = [
    ['friendship', { groupId: '', status: 'pending' },
      'friendships/planner_target/plannerGrants/planner_target', 'New plan for you'],
    ['group', { groupId: 'g1', status: 'pending' },
      'groups/g1/plannerGrants/planner_target', 'New group plan for you'],
    ['emergency', { groupId: '', status: 'approved', tier: 'emergency' },
      'friendships/planner_target/emergencyGrants/planner_target', null],
  ];
  for (const [name, shape, grantPath, title] of cases) {
    const harness = context({
      'scheduleItems/target/items/item-1': {
        targetUid: 'target', createdByUid: 'planner', title: 'Gym',
        scheduledInstantUtc: future, ...shape,
      },
      [grantPath]: { granted: true },
      'users/planner': { name: 'Test Planner' },
      'groups/g1': { name: 'Team' },
    });
    const result = await sendEventNotification(harness.ctx, {
      event: 'created', targetUid: 'target', itemId: 'item-1',
    });
    assert.equal(result.reason, 'sent', name);
    assert.deepEqual(harness.listed, ['users/target/fcmTokens'], name);
    assert.equal(harness.patched[0].fields.notifiedCreated, true, name);
    if (title) {
      assert.equal(harness.sent[0].notification.title, title, name);
      assert.equal(harness.sent[0].android.priority, 'high', name);
      assert.match(harness.sent[0].notification.body, /^Test Planner planned Gym for you/, name);
    } else {
      assert.equal(harness.sent[0].data.command, 'scheduleReminder', name);
    }

    // No token: nothing sent, nothing stamped, so a later retry can deliver.
    const noTokens = context({
      'scheduleItems/target/items/item-1': {
        targetUid: 'target', createdByUid: 'planner', title: 'Gym', ...shape,
      },
      [grantPath]: { granted: true },
    }, { tokens: [] });
    const none = await sendEventNotification(noTokens.ctx, {
      event: 'created', targetUid: 'target', itemId: 'item-1',
    });
    assert.equal(none.reason, 'no-tokens', name);
    assert.equal(noTokens.patched.length, 0, name);

    // Replay after delivery is a no-op.
    const replay = context({
      'scheduleItems/target/items/item-1': {
        targetUid: 'target', createdByUid: 'planner', title: 'Gym',
        notifiedCreated: true, ...shape,
      },
      [grantPath]: { granted: true },
    });
    const again = await sendEventNotification(replay.ctx, {
      event: 'created', targetUid: 'target', itemId: 'item-1',
    });
    assert.equal(again.reason, 'already-notified', name);
    assert.equal(replay.sent.length, 0, name);
  }
});

test('a friendship plan with an empty groupId is never dropped as malformed', async () => {
  // Regression for the stale Worker (2026-09-19) that required a truthy
  // groupId and silently dropped every friendship-plan push.
  const harness = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target', createdByUid: 'planner', groupId: '', status: 'pending',
    },
    'friendships/planner_target/plannerGrants/planner_target': { granted: true },
  });
  const result = await sendEventNotification(harness.ctx, {
    event: 'created', targetUid: 'target', itemId: 'item-1',
  });
  assert.notEqual(result.reason, 'item-missing-fields');
  assert.equal(result.sent, 1);
});

// --- item 15: group emergency plans (2026-09-26) ------------------------------

test('friends may plan untagged; fellow group members may plan group-tagged', async () => {
  const item = { groupId: '' };
  const db = (docs) => ({ getDoc: async (p) => docs[p] ?? null });
  const friends = { 'friendships/planner_target': {} };
  const team = { 'groups/g1': { memberUids: ['planner', 'target'] } };
  // Friends: yes, with no grant document at all.
  assert.equal(await hasActiveItemGrant(db(friends), item, 'planner', 'target'), true);
  // A leftover granted:false doc takes nothing away.
  assert.equal(await hasActiveItemGrant(db({ ...friends,
    'friendships/planner_target/plannerGrants/planner_target': { granted: false } }), item, 'planner', 'target'), true);
  // Not friends: no — a leftover granted:true doc counts for nothing.
  assert.equal(await hasActiveItemGrant(db({}), item, 'planner', 'target'), false);
  assert.equal(await hasActiveItemGrant(db({
    'friendships/planner_target/plannerGrants/planner_target': { granted: true } }), item, 'planner', 'target'), false);
  // A group item: both members — yes, no grant needed.
  assert.equal(await hasActiveItemGrant(db(team), { groupId: 'g1' }, 'planner', 'target'), true);
  // One of them left the group — no, even with a leftover grant.
  assert.equal(await hasActiveItemGrant(db({
    'groups/g1': { memberUids: ['target'] },
    'groups/g1/plannerGrants/planner_target': { granted: true } }), { groupId: 'g1' }, 'planner', 'target'), false);
  // Friends do not carry a group item for a group they do not share.
  assert.equal(await hasActiveItemGrant(db(friends), { groupId: 'g1' }, 'planner', 'target'), false);
});

test('the retired planning-permission events are not friend events', async () => {
  for (const event of ['planningRequest', 'planningApprove']) {
    const harness = context({ 'users/sender': { name: 'Test Person' } });
    const result = await sendFriendNotification(harness.ctx, {
      event, fromUid: 'sender', toUid: 'recipient', kind: 'normal',
    });
    assert.equal(result.reason, 'bad-args', event);
    assert.equal(harness.sent.length, 0, event);
  }
});

test('a group emergency plan reaches the target as a group-labelled alarm command', async () => {
  const harness = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: 'g1',
      title: 'Evacuate',
      status: 'approved',
      tier: 'emergency',
      scheduledInstantUtc: '2030-01-01T10:00:00.000Z',
    },
    'groups/g1': { name: 'Family', memberUids: ['planner', 'target'] },
    'users/planner': { name: 'Test Planner' },
  });
  const result = await sendEventNotification(harness.ctx, {
    event: 'created', targetUid: 'target', itemId: 'item-1',
  });
  assert.equal(result.reason, 'sent');
  assert.equal(harness.sent[0].data.command, 'scheduleReminder');
  assert.equal(harness.sent[0].data.pushTitle, 'New group alarm for you');
  assert.equal(
    harness.sent[0].data.pushBody,
    'Test Planner set Evacuate for you in Family',
  );
});

// F2: one permission — between members who are not friends, the group grant
// authorises pushes about any alarm in that group (legacy emergency tier too).
test('a group grant authorises pushes about a group alarm between non-friends', async () => {
  const harness = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target',
      createdByUid: 'planner',
      groupId: 'g1',
      title: 'Evacuate',
      status: 'approved',
      tier: 'emergency',
      outcome: { result: 'done' },
    },
    'groups/g1/plannerGrants/planner_target': { granted: true },
  });
  for (const event of ['created', 'outcome']) {
    const result = await sendEventNotification(harness.ctx, {
      event, targetUid: 'target', itemId: 'item-1',
    });
    assert.equal(result.reason, 'sent', event);
  }
  assert.equal(harness.sent.length, 2);
});

// --- F2: the "Emergency" label is retired ------------------------------------

test('no push ever says Emergency — not even for a legacy emergency-tier item', () => {
  for (const tier of ['emergency', 'normal', undefined]) {
    for (const status of ['approved', 'pending']) {
      for (const groupName of [null, 'Team']) {
        for (const [event, subtype] of [
          ['created', null], ['withdrawn', null], ['decided', 'approved'],
          ['outcome', 'done'], ['outcome', 'skipped'], ['dismissed', null],
        ]) {
          const message = buildMessage(event, subtype, {
            title: 'Meds', status, tier, scheduledInstantUtc: '2030-01-01T10:00:00Z',
          }, 't', 'i', { actorName: 'Test Person', groupName });
          const text = message.notification
            ? `${message.notification.title} ${message.notification.body}`
            : `${message.data.pushTitle} ${message.data.pushBody}`;
          assert.doesNotMatch(text, /emergency/i, `${tier}/${status}/${event}/${groupName}`);
        }
      }
    }
  }
});

test('every NEW alarm is an alarm command, so a killed app still arms it', () => {
  const message = buildMessage('created', null, {
    title: 'Meds', note: 'With water', status: 'approved', tier: 'normal',
    scheduledInstantUtc: '2030-01-01T10:00:00.000Z',
  }, 't', 'i', { actorName: 'Test Planner', groupName: null });
  assert.equal(message.notification, undefined, 'data-only');
  assert.equal(message.android.priority, 'high');
  assert.equal(message.data.command, 'scheduleReminder');
  assert.equal(message.data.title, 'Test Planner planned Meds for you');
  assert.equal(message.data.body, 'With water');
  assert.equal(message.data.pushTitle, 'New alarm for you');
  assert.equal(message.data.pushBody, 'Test Planner set Meds for you');
  // A legacy pending plan is still a visible notification.
  const legacy = buildMessage('created', null, { title: 'Meds', status: 'pending' }, 't', 'i', {});
  assert.equal(legacy.data.command, undefined);
  assert.equal(legacy.notification.title, 'New plan for you');
});

// --- item 32c-2: voice-note fallback → planner ------------------------------

function voiceItem(extra = {}) {
  return {
    targetUid: 'target',
    createdByUid: 'planner',
    groupId: '',
    title: 'Wake up',
    status: 'approved',
    voiceNote: { sha256: 'a'.repeat(64), durationMs: 12000, sizeBytes: 9000 },
    alarm: { voiceFallbackAt: '2030-01-01T07:00:00Z' },
    ...extra,
  };
}

test('a recorded voice fallback tells the planner, once', async () => {
  const harness = context({
    'scheduleItems/target/items/item-1': voiceItem(),
    'friendships/planner_target/plannerGrants/planner_target': { granted: true },
    'users/target': { name: 'Test Target' },
  });
  const result = await sendEventNotification(harness.ctx, {
    event: 'voiceFallback', targetUid: 'target', itemId: 'item-1',
  });
  assert.equal(result.recipientUid, 'planner');
  assert.deepEqual(harness.sent[0].notification, {
    title: "Voice note didn't play",
    body: "Test Target's alarm for Wake up rang with the normal ringtone. Your voice note couldn't play.",
  });
  assert.equal(harness.patched[0].fields.notifiedVoiceFallback, true);
});

test('no voice fallback without the recorded fact, a voice note, or twice', async () => {
  const docs = (item) => ({
    'scheduleItems/target/items/item-1': item,
    'friendships/planner_target/plannerGrants/planner_target': { granted: true },
  });
  for (const [item, reason] of [
    [voiceItem({ alarm: {} }), 'no-voice-fallback'],
    [voiceItem({ alarm: undefined }), 'no-voice-fallback'],
    [voiceItem({ voiceNote: undefined }), 'no-voice-fallback'],
    [voiceItem({ notifiedVoiceFallback: true }), 'already-notified'],
  ]) {
    const harness = context(docs(item));
    const result = await sendEventNotification(harness.ctx, {
      event: 'voiceFallback', targetUid: 'target', itemId: 'item-1',
    });
    assert.equal(result.reason, reason);
    assert.equal(harness.sent.length, 0);
  }
});

test('the emergency alarm command carries the voice note only when there is one', () => {
  const base = {
    title: 'Meds', status: 'approved', tier: 'emergency',
    scheduledInstantUtc: '2030-01-01T10:00:00.000Z', createdByUid: 'planner',
  };
  const withVoice = buildMessage('created', null, {
    ...base, voiceNote: { sha256: 'b'.repeat(64), sizeBytes: 9000, durationMs: 21000 },
  }, 'target', 'i', { actorName: 'Test Planner', groupName: null });
  assert.equal(withVoice.data.voiceSha256, 'b'.repeat(64));
  assert.equal(withVoice.data.voiceSizeBytes, '9000');
  // 2026-10-05: the note's length rides along for the ring queue.
  assert.equal(withVoice.data.voiceDurationMs, '21000');
  for (const value of Object.values(withVoice.data)) assert.equal(typeof value, 'string');
  const plain = buildMessage('created', null, base, 'target', 'i', {});
  assert.equal(plain.data.voiceSha256, undefined);
});

// --- item 3: join requests go to every admin (2026-09-27) --------------------

function joinHarness({ request = {}, group = {}, tokens = {} } = {}) {
  const docs = {
    'groups/g1/joinRequests/candidate': {
      candidateUid: 'candidate', candidateName: 'Test Candidate',
      requestedByUid: 'candidate', source: 'code', status: 'pending',
      ...request,
    },
    'groups/g1': {
      name: 'Team', ownerUid: 'owner',
      memberUids: ['owner', 'admin2', 'member'], adminUids: ['owner', 'admin2'],
      ...group,
    },
    'users/member': { name: 'Test Member' },
  };
  const sent = [];
  const patched = [];
  const listed = [];
  return {
    sent, patched, listed,
    ctx: {
      db: {
        getDoc: async (p) => docs[p] ?? null,
        listDocIds: async (p) => {
          listed.push(p);
          const uid = p.split('/')[1];
          return tokens[uid] ?? [`${uid}-token`];
        },
        deleteDoc: async () => {},
        patchDoc: async (path, fields) => patched.push({ path, fields }),
      },
      fcm: { send: async (token, message) => { sent.push({ token, message }); return { ok: true }; } },
    },
  };
}

test('a code request pushes every admin — not plain members — once', async () => {
  const h = joinHarness();
  const res = await sendFriendNotification(h.ctx, {
    event: 'groupJoinRequested', fromUid: 'candidate', toUid: 'candidate', groupId: 'g1',
  });
  assert.equal(res.reason, 'sent');
  assert.deepEqual(h.sent.map((s) => s.token).sort(), ['admin2-token', 'owner-token']);
  assert.equal(h.sent[0].message.notification.title, 'Join request');
  assert.equal(h.sent[0].message.notification.body, 'Test Candidate wants to join Team');
  assert.equal(h.sent[0].message.data.type, 'groupJoinRequested');
  assert.equal(h.sent[0].message.data.groupId, 'g1');
  assert.equal(h.patched[0].path, 'groups/g1/joinRequests/candidate');
  assert.equal(h.patched[0].fields.notifiedRequested, true);
});

test('a member invitation names the inviter, and never pushes the inviter', async () => {
  const h = joinHarness({
    request: { requestedByUid: 'admin2', source: 'friend' },
  });
  await sendFriendNotification(h.ctx, {
    event: 'groupJoinRequested', fromUid: 'admin2', toUid: 'candidate', groupId: 'g1',
  });
  assert.deepEqual(h.sent.map((s) => s.token), ['owner-token']);

  const m = joinHarness({ request: { requestedByUid: 'member', source: 'friend' } });
  await sendFriendNotification(m.ctx, {
    event: 'groupJoinRequested', fromUid: 'member', toUid: 'candidate', groupId: 'g1',
  });
  assert.equal(
    m.sent[0].message.notification.body,
    'Test Member invited Test Candidate to join Team',
  );
});

test('a pre-admins group pushes its owner; an admin who left is skipped', async () => {
  const legacy = joinHarness({ group: { adminUids: undefined } });
  await sendFriendNotification(legacy.ctx, {
    event: 'groupJoinRequested', fromUid: 'candidate', toUid: 'candidate', groupId: 'g1',
  });
  assert.deepEqual(legacy.sent.map((s) => s.token), ['owner-token']);

  const left = joinHarness({ group: { memberUids: ['owner', 'member'] } });
  await sendFriendNotification(left.ctx, {
    event: 'groupJoinRequested', fromUid: 'candidate', toUid: 'candidate', groupId: 'g1',
  });
  assert.deepEqual(left.sent.map((s) => s.token), ['owner-token']);
});

test('no push for a decided, forged, missing or already-notified request', async () => {
  const cases = [
    [{ request: { status: 'approved' } }, 'candidate', 'not-pending'],
    [{ request: { status: 'rejected' } }, 'candidate', 'not-pending'],
    [{}, 'member', 'not-pending'],
    [{ request: { notifiedRequested: true } }, 'candidate', 'already-notified'],
  ];
  for (const [opts, from, reason] of cases) {
    const h = joinHarness(opts);
    const res = await sendFriendNotification(h.ctx, {
      event: 'groupJoinRequested', fromUid: from, toUid: 'candidate', groupId: 'g1',
    });
    assert.equal(res.reason, reason);
    assert.equal(h.sent.length, 0);
  }
  const h = joinHarness();
  const res = await sendFriendNotification(h.ctx, {
    event: 'groupJoinRequested', fromUid: 'candidate', toUid: 'someone', groupId: 'g1',
  });
  assert.equal(res.reason, 'request-not-found');
});

test('groupAdminUids: creator always, listed admins who are still members', () => {
  assert.deepEqual(
    groupAdminUids({ ownerUid: 'o', memberUids: ['o', 'a', 'm'], adminUids: ['a', 'gone'] }),
    ['o', 'a'],
  );
  assert.deepEqual(groupAdminUids({ ownerUid: 'o', memberUids: ['o'] }), ['o']);
  assert.deepEqual(groupAdminUids(null), []);
});

test('an admin-added member is told they were added', async () => {
  const docs = {
    'groups/g1/joinRequests/candidate': { status: 'approved', source: 'admin' },
    'groups/g1': { name: 'Team', memberUids: ['owner', 'candidate'] },
    'users/owner': { name: 'Test Owner' },
  };
  const sent = [];
  const ctx = {
    db: {
      getDoc: async (p) => docs[p] ?? null,
      listDocIds: async () => ['t'],
      deleteDoc: async () => {},
      patchDoc: async () => {},
    },
    fcm: { send: async (_t, m) => { sent.push(m); return { ok: true }; } },
  };
  await sendFriendNotification(ctx, {
    event: 'groupJoinApproved', fromUid: 'owner', toUid: 'candidate', groupId: 'g1',
  });
  assert.equal(sent[0].notification.title, 'Added to a group');
});

// --- item 6: "unavailable" push with the Uh-Oh tone (2026-09-27) -------------

test('an unanswered alarm tells the planner, on the Uh-Oh channel, once', async () => {
  const item = {
    targetUid: 'target', createdByUid: 'planner', groupId: '', title: 'Gym',
    status: 'approved', alarm: { unavailableAt: '2030-01-01T10:01:00Z' },
  };
  const h = context({
    'scheduleItems/target/items/item-1': item,
    'friendships/planner_target': { participants: [] },
    'users/target': { name: 'Test Target' },
  });
  const res = await sendEventNotification(h.ctx, {
    event: 'unavailable', targetUid: 'target', itemId: 'item-1',
  });
  assert.equal(res.reason, 'sent');
  assert.deepEqual(h.listed, ['users/planner/fcmTokens']);
  assert.equal(h.sent[0].notification.title, 'Test Target was unavailable');
  assert.equal(
    h.sent[0].notification.body,
    'Test Target was unavailable to dismiss the task: Gym you planned for them.',
  );
  assert.equal(h.sent[0].android.notification.channel_id, 'planner_unavailable');
  assert.equal(h.patched[0].fields.notifiedUnavailable, true);

  const again = context({
    'scheduleItems/target/items/item-1': { ...item, notifiedUnavailable: true },
    'friendships/planner_target': { participants: [] },
  });
  const res2 = await sendEventNotification(again.ctx, {
    event: 'unavailable', targetUid: 'target', itemId: 'item-1',
  });
  assert.equal(res2.reason, 'already-notified');
});

test('no unavailable push without the recorded fact, or for a self-plan', async () => {
  const none = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target', createdByUid: 'planner', groupId: '', status: 'approved',
    },
    'friendships/planner_target': { participants: [] },
  });
  const r1 = await sendEventNotification(none.ctx, {
    event: 'unavailable', targetUid: 'target', itemId: 'item-1',
  });
  assert.equal(r1.sent, 0);

  const self = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target', createdByUid: 'target', groupId: '', status: 'approved',
      alarm: { unavailableAt: '2030-01-01T10:01:00Z' },
    },
  });
  const r2 = await sendEventNotification(self.ctx, {
    event: 'unavailable', targetUid: 'target', itemId: 'item-1',
  });
  assert.equal(r2.sent, 0);
});

test('other item pushes stay on the normal activity channel', async () => {
  const h = context({
    'scheduleItems/target/items/item-1': {
      targetUid: 'target', createdByUid: 'planner', groupId: '', status: 'approved',
      title: 'Gym', alarm: { dismissedAt: '2030-01-01T10:00:30Z' },
    },
    'friendships/planner_target': { participants: [] },
  });
  await sendEventNotification(h.ctx, {
    event: 'dismissed', targetUid: 'target', itemId: 'item-1',
  });
  assert.equal(h.sent[0].android.notification.channel_id, 'planner_activity');
});


// ---- atomic dedup claim (2026-09-27 device bug: "dismissed" pushed 3x) ----

// A db double with real compare-and-set semantics on `updateTime`.
function casContext(docs, { tokenResult = { ok: true } } = {}) {
  const versions = {};
  const bump = (path) => { versions[path] = (versions[path] ?? 0) + 1; };
  for (const path of Object.keys(docs)) bump(path);
  const sent = [];
  const tick = () => new Promise((r) => setImmediate(r));
  return {
    sent,
    docs,
    ctx: {
      db: {
        getDoc: async (path) => { await tick(); return docs[path] ?? null; },
        getDocWithMeta: async (path) => {
          await tick();
          return docs[path]
            ? { data: { ...docs[path] }, updateTime: String(versions[path]) }
            : null;
        },
        patchDocIfUnchanged: async (path, fields, updateTime) => {
          await tick();
          if (String(versions[path]) !== updateTime) return false;
          docs[path] = { ...docs[path], ...fields };
          bump(path);
          return true;
        },
        patchDoc: async (path, fields) => {
          await tick();
          docs[path] = { ...docs[path], ...fields };
          bump(path);
        },
        listDocIds: async () => { await tick(); return ['planner-token']; },
        deleteDoc: async () => {},
      },
      fcm: {
        send: async (_token, message) => {
          await tick();
          sent.push(message);
          return tokenResult;
        },
      },
    },
  };
}

const claimItem = () => ({
  targetUid: 'target',
  createdByUid: 'planner',
  groupId: '',
  title: 'Wake up',
  status: 'approved',
  alarm: { dismissedAt: '2030-01-01T00:00:00.000Z' },
});

test('three simultaneous reports of one dismissal push exactly once', async () => {
  const h = casContext({
    'scheduleItems/target/items/item-1': claimItem(),
    'friendships/planner_target': { uidA: 'planner', uidB: 'target' },
    'users/target': { name: 'Test Target' },
  });
  const args = { event: 'dismissed', targetUid: 'target', itemId: 'item-1' };
  const results = await Promise.all([
    sendEventNotification(h.ctx, args),
    sendEventNotification(h.ctx, args),
    sendEventNotification(h.ctx, args),
  ]);
  assert.equal(h.sent.length, 1);
  assert.equal(results.filter((r) => r.sent === 1).length, 1);
  assert.equal(results.filter((r) => r.reason === 'already-notified').length, 2);
  assert.equal(h.docs['scheduleItems/target/items/item-1'].notifiedDismissed, true);
});

test('a claim that delivered nothing is released for a later attempt', async () => {
  const h = casContext({
    'scheduleItems/target/items/item-1': claimItem(),
    'friendships/planner_target': { uidA: 'planner', uidB: 'target' },
  }, { tokenResult: { ok: false, error: 'OTHER' } });
  const args = { event: 'dismissed', targetUid: 'target', itemId: 'item-1' };
  const first = await sendEventNotification(h.ctx, args);
  assert.equal(first.reason, 'no-delivery');
  assert.equal(h.docs['scheduleItems/target/items/item-1'].notifiedDismissed, null);
  const second = await sendEventNotification(h.ctx, args);
  assert.equal(second.reason, 'no-delivery'); // tried again, not "already"
});

test('a concurrent unrelated write does not lose the push (claim retries)', async () => {
  const h = casContext({
    'scheduleItems/target/items/item-1': claimItem(),
    'friendships/planner_target': { uidA: 'planner', uidB: 'target' },
  });
  const path = 'scheduleItems/target/items/item-1';
  const racing = h.ctx.db.patchDocIfUnchanged;
  let once = true;
  h.ctx.db.patchDocIfUnchanged = async (p, f, t) => {
    if (once) {
      once = false;
      await h.ctx.db.patchDoc(path, { outcome: { result: 'done' } });
    }
    return racing(p, f, t);
  };
  const res = await sendEventNotification(h.ctx, {
    event: 'dismissed', targetUid: 'target', itemId: 'item-1',
  });
  assert.equal(res.sent, 1);
  assert.equal(h.sent.length, 1);
});

test('the unavailable push rides the Uh-Oh channel and is claimed once', async () => {
  const item = {
    ...claimItem(),
    alarm: { unavailableAt: '2030-01-01T00:01:00.000Z' },
  };
  const h = casContext({
    'scheduleItems/target/items/item-1': item,
    'friendships/planner_target': { uidA: 'planner', uidB: 'target' },
  });
  const args = { event: 'unavailable', targetUid: 'target', itemId: 'item-1' };
  await Promise.all([
    sendEventNotification(h.ctx, args),
    sendEventNotification(h.ctx, args),
  ]);
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].android.notification.channel_id, 'planner_unavailable');
});

// R3 (2026-10-02): the killed-app alarm says who planned it, word for word
// the app's alarmHeadline(); both sides read the same fixture.
test('the alarm command carries the app\'s alarm sentence (shared fixture)', async () => {
  const { readFile } = await import('node:fs/promises');
  const cases = JSON.parse(await readFile(
    new URL('../../test/fixtures/alarm_headline_cases.json', import.meta.url),
  ));
  assert.ok(cases.length >= 5);
  for (const c of cases) {
    assert.equal(alarmHeadline(c.item, c.plannerName), c.expected, c.name);
  }
});

test('a killed-app alarm for someone else names the planner, voice too', () => {
  const plain = buildMessage('created', null, {
    title: 'Walk', status: 'approved', targetUid: 't', createdByUid: 'p',
    scheduledInstantUtc: '2030-01-01T10:00:00.000Z',
  }, 't', 'i', { actorName: 'Test Planner', groupName: null });
  assert.equal(plain.data.title, 'Test Planner planned Walk for you');
  const voice = buildMessage('created', null, {
    title: 'Voice alarm', status: 'approved', targetUid: 't', createdByUid: 'p',
    voiceNote: { sha256: 'a'.repeat(64), sizeBytes: 100 },
    scheduledInstantUtc: '2030-01-01T10:00:00.000Z',
  }, 't', 'i', { actorName: 'Test Planner', groupName: null });
  assert.equal(voice.data.title, 'Test Planner sent you a voice alarm');
  const unnamed = buildMessage('created', null, {
    title: 'Walk', status: 'approved', targetUid: 't', createdByUid: 'p',
    scheduledInstantUtc: '2030-01-01T10:00:00.000Z',
  }, 't', 'i', {});
  assert.equal(unnamed.data.title, 'Someone planned Walk for you');
});
