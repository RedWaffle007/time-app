import assert from 'node:assert/strict';
import test from 'node:test';

import {
  buildSummaryMessage,
  membersOn,
  noteSilentGroupMembers,
  summaryListFor,
  summaryTitle,
} from '../src/group-summary.js';
import {
  buildMessage,
  isNegativeItemEvent,
  sendEventNotification,
  sendFriendNotification,
} from '../src/notify.js';
import { expirePlanRequests } from '../src/plan-request-expiry.js';

// "Uh-Oh!" for every negative event, and live group lists (2026-09-28).

const UH_OH = 'planner_unavailable';
const NORMAL = 'planner_activity';
const AT = '2030-10-04T18:00:00Z';
const RANG_OUT = { unavailableAt: '2030-10-04T18:01:00Z' };

function db(seed = {}) {
  const docs = { ...seed };
  const sent = [];
  const patched = [];
  const merge = (a, b) => {
    const out = { ...(a || {}) };
    for (const [k, v] of Object.entries(b)) {
      out[k] = v && typeof v === 'object' && !(v instanceof Date) ? merge(out[k], v) : v;
    }
    return out;
  };
  return {
    docs, sent, patched,
    ctx: {
      db: {
        getDoc: async (p) => docs[p] ?? null,
        patchPaths: async (p, fields) => { docs[p] = merge(docs[p], fields); },
        patchDoc: async (p, fields) => { patched.push({ p, fields }); docs[p] = merge(docs[p], fields); },
        patchDocIfUnchanged: async (p, fields) => { docs[p] = merge(docs[p], fields); return true; },
        listDocIds: async (p) => [`${p.split('/')[1]}-token`],
        deleteDoc: async () => {},
        listItemsScheduledBetween: async () => docs.__rows || [],
        listDuePlanRequests: async () => docs.__requests || [],
      },
      fcm: { send: async (token, message) => { sent.push({ token, message }); return { ok: true }; } },
    },
  };
}

const plain = {
  title: 'Gym', targetUid: 'target', createdByUid: 'planner', groupId: '',
  status: 'approved', scheduledInstantUtc: AT,
};
const channelOf = (m) => m.android.notification.channel_id;
const msg = (event, subtype, item) =>
  buildMessage(event, subtype, item, 'target', 'i1', { actorName: 'Test Target', groupName: null });

test('1-to-1: which item events are negative', () => {
  assert.equal(isNegativeItemEvent('unavailable', undefined, plain), true);
  assert.equal(isNegativeItemEvent('outcome', 'skipped', { ...plain, alarm: RANG_OUT }), true);
  assert.equal(isNegativeItemEvent('outcome', 'skipped', plain), false); // skipped after dismissing
  assert.equal(isNegativeItemEvent('outcome', 'done', { ...plain, alarm: RANG_OUT }), false);
  assert.equal(isNegativeItemEvent('dismissed', undefined, plain), false);
});

test('1-to-1: Skip on the missed popup plays Uh-Oh; everything else is normal', () => {
  const skippedLate = msg('outcome', 'skipped', { ...plain, alarm: RANG_OUT });
  assert.equal(channelOf(skippedLate), UH_OH);
  assert.equal(skippedLate.data.uhOh, 'true');
  assert.equal(channelOf(msg('unavailable', undefined, plain)), UH_OH);
  for (const m of [
    msg('outcome', 'skipped', plain),
    msg('outcome', 'done', { ...plain, alarm: RANG_OUT }),
    msg('dismissed', undefined, plain),
    msg('withdrawn', undefined, plain),
  ]) {
    assert.equal(channelOf(m), NORMAL);
    assert.equal(m.data.uhOh, undefined);
  }
});

const member = (uid, extra = {}) => ({
  ...plain, targetUid: uid, groupId: 'g1', ...extra,
});

test('group: which events feed which live list', () => {
  const m = member('a');
  assert.equal(summaryListFor('unavailable', undefined, m), 'missed');
  assert.equal(summaryListFor('dismissed', undefined, m), 'dismissed');
  assert.equal(summaryListFor('outcome', 'skipped', member('a', { alarm: RANG_OUT })), 'skipped');
  assert.equal(summaryListFor('outcome', 'done', member('a', { alarm: RANG_OUT })), 'done');
  assert.equal(
    summaryListFor('outcome', 'done', member('a', { alarm: RANG_OUT, voiceNote: { d: 1 } })),
    'heard',
  );
  // A Done/Skip after dismissing stays an individual push.
  assert.equal(summaryListFor('outcome', 'done', m), null);
  assert.equal(summaryListFor('outcome', 'skipped', m), null);
  // The planner's own copy, and 1-to-1 plans, are never summarised.
  assert.equal(summaryListFor('unavailable', undefined, member('planner')), null);
  assert.equal(summaryListFor('unavailable', undefined, plain), null);
});

test('group: titles, tones and one tag per list', () => {
  assert.equal(summaryTitle('missed', { task: 'Gym' }), 'Didn\'t dismiss "Gym"');
  assert.equal(summaryTitle('missed', { voice: true }), "Didn't dismiss your voice note");
  assert.equal(summaryTitle('dismissed', { voice: true }), 'Heard your voice note');
  assert.equal(summaryTitle('skipped', { task: 'Gym' }), 'Skipped "Gym"');
  assert.equal(summaryTitle('done', { task: 'Gym' }), 'Done "Gym"');
  assert.equal(summaryTitle('heard', { voice: true }), 'Heard your voice note late');
  assert.equal(summaryTitle('noResponse', { task: 'Gym' }), 'Didn\'t respond to "Gym"');
  for (const [list, tone] of [
    ['missed', UH_OH], ['skipped', UH_OH], ['noResponse', UH_OH],
    ['dismissed', NORMAL], ['done', NORMAL], ['heard', NORMAL],
  ]) {
    const m = buildSummaryMessage(list, {
      task: 'Gym', names: ['Test A', 'Test B'], groupName: 'Team', groupId: 'g1', id: 'k',
    });
    assert.equal(channelOf(m), tone, list);
    assert.equal(m.data.uhOh === 'true', tone === UH_OH, list);
    assert.equal(m.android.notification.tag, `group-k-${list}`);
    assert.equal(m.data.tag, `group-k-${list}`);
    assert.equal(m.notification.body, 'Test A, Test B · Team');
    assert.equal(m.data.type, 'groupPlanSummary');
  }
});

test('group: a member who dismissed never also counts as not dismissing', () => {
  const doc = { lists: { missed: { a: 1, b: 2 }, dismissed: { b: 3 } } };
  assert.deepEqual(membersOn(doc, 'missed'), ['a']);
  assert.deepEqual(membersOn(doc, 'dismissed'), ['b']);
});

test('group: each ring-out updates ONE live Uh-Oh list at once', async () => {
  const h = db({
    // The ring-out fact is written first; the push follows it.
    'scheduleItems/a/items/ia': member('a', { alarm: RANG_OUT }),
    'scheduleItems/b/items/ib': member('b', { alarm: RANG_OUT }),
    'groups/g1': { name: 'Team', memberUids: ['planner', 'a', 'b'] },
    'users/a': { name: 'Test A' },
    'users/b': { name: 'Test B' },
  });
  await sendEventNotification(h.ctx, { event: 'unavailable', targetUid: 'a', itemId: 'ia' });
  await sendEventNotification(h.ctx, { event: 'unavailable', targetUid: 'b', itemId: 'ib' });
  assert.equal(h.sent.length, 2);
  const [first, second] = h.sent.map((s) => s.message);
  assert.equal(first.notification.body, 'Test A · Team');
  assert.equal(second.notification.body, 'Test A, Test B · Team');
  assert.equal(first.android.notification.tag, second.android.notification.tag);
  assert.equal(channelOf(second), UH_OH);
  assert.equal(h.sent[0].token, 'planner-token');
});

test('group: dismissals go to the normal list', async () => {
  const h = db({
    'scheduleItems/a/items/ia': member('a', { alarm: { dismissedAt: AT } }),
    'groups/g1': { name: 'Team', memberUids: ['planner', 'a'] },
    'users/a': { name: 'Test A' },
  });
  await sendEventNotification(h.ctx, { event: 'dismissed', targetUid: 'a', itemId: 'ia' });
  const m = h.sent[0].message;
  assert.equal(m.notification.title, 'Dismissed "Gym"');
  assert.equal(channelOf(m), NORMAL);
});

test('group: a phone that never reported joins the Uh-Oh list via the cron', async () => {
  const row = (uid, extra = {}) => ({
    path: `scheduleItems/${uid}/items/i${uid}`, data: member(uid, extra),
  });
  const h = db({
    __rows: [
      row('silent'),
      row('dismissed', { alarm: { dismissedAt: AT } }),
      row('rangout', { alarm: RANG_OUT }),
      row('answered', { outcome: { result: 'done' } }),
    ],
    'groups/g1': { name: 'Team', memberUids: ['planner', 'silent'] },
    'users/silent': { name: 'Test Silent' },
  });
  const result = await noteSilentGroupMembers(h.ctx, new Date('2030-10-04T18:05:00Z'));
  assert.equal(result.noted, 1);
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].message.notification.body, 'Test Silent · Team');
  assert.equal(channelOf(h.sent[0].message), UH_OH);
  // Already on the list: a second pass adds nobody.
  const again = await noteSilentGroupMembers(h.ctx, new Date('2030-10-04T18:07:00Z'));
  assert.equal(again.noted, 0);
});

test('an expired request: Uh-Oh for the requester, normal for the friend', async () => {
  const h = db({
    __requests: [{
      id: 'r1', updateTime: 'u1',
      data: {
        requesterUid: 'requester', plannerUid: 'friend', status: 'pending',
        title: 'Pills', timezone: 'UTC', windowStartUtc: AT,
      },
    }],
  });
  await expirePlanRequests(h.ctx, new Date('2030-10-04T18:01:00Z'));
  const toRequester = h.sent.find((s) => s.token === 'requester-token').message;
  const toFriend = h.sent.find((s) => s.token === 'friend-token').message;
  assert.equal(channelOf(toRequester), UH_OH);
  assert.equal(toRequester.data.uhOh, 'true');
  assert.equal(channelOf(toFriend), NORMAL);
});

test('a declined request: the requester hears Uh-Oh, once', async () => {
  const h = db({
    'planRequests/r1': {
      requesterUid: 'requester', plannerUid: 'friend', status: 'declined', title: 'Pills',
    },
    'users/friend': { name: 'Test Friend' },
  });
  const args = {
    event: 'planRequestDeclined', fromUid: 'requester', toUid: 'friend', planRequestId: 'r1',
  };
  const res = await sendFriendNotification(h.ctx, args);
  assert.equal(res.reason, 'sent');
  assert.equal(res.recipientUid, 'requester');
  const m = h.sent[0].message;
  assert.deepEqual(m.notification, {
    title: 'Plan request declined',
    body: 'Test Friend declined your plan request for "Pills".',
  });
  assert.equal(channelOf(m), UH_OH);
  assert.equal(m.data.uhOh, 'true');
  assert.equal((await sendFriendNotification(h.ctx, args)).reason, 'already-notified');
});

test('a request that is not declined sends nothing', async () => {
  const h = db({
    'planRequests/r1': { requesterUid: 'requester', plannerUid: 'friend', status: 'pending' },
  });
  const res = await sendFriendNotification(h.ctx, {
    event: 'planRequestDeclined', fromUid: 'requester', toUid: 'friend', planRequestId: 'r1',
  });
  assert.equal(res.reason, 'not-declined');
  assert.equal(h.sent.length, 0);
});

test('REST: a summary entry is written by its own field path, no precondition', async () => {
  const { makeFirestoreDb } = await import('../src/firestore-rest.js');
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    return new Response('{}', { status: 200 });
  };
  try {
    const fdb = makeFirestoreDb('proj', 'token');
    await fdb.patchPaths(
      'groupPlanSummaries/g1_planner_1',
      { lists: { missed: { uid_a_1: 5 } } },
      ['lists.missed.`uid_a_1`'],
    );
  } finally {
    globalThis.fetch = original;
  }
  assert.equal(calls.length, 1);
  assert.equal(calls[0].init.method, 'PATCH');
  assert.ok(calls[0].url.includes(
    `updateMask.fieldPaths=${encodeURIComponent('lists.missed.`uid_a_1`')}`,
  ));
  assert.ok(!calls[0].url.includes('currentDocument'));
  const body = JSON.parse(calls[0].init.body);
  assert.deepEqual(
    body.fields.lists.mapValue.fields.missed.mapValue.fields.uid_a_1,
    { integerValue: '5' },
  );
});
