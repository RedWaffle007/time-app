import assert from 'node:assert/strict';
import test from 'node:test';

import {
  ALARM_TIMEOUT_EVENT,
  MAX_AFTER_SCHEDULED_MS,
  MIN_AFTER_SCHEDULED_MS,
  alarmTimeoutDecision,
  recordAlarmTimeout,
} from '../src/alarm-timeout.js';
import worker, { alarmTimeoutAndNotify } from '../src/index.js';

// 2026-09-27: the Uh-Oh push waited for the target to open the app. The
// target's phone now reports the timeout natively and the Worker records it.

const SCHEDULED = Date.parse('2030-01-01T09:00:00.000Z');
const PATH = 'scheduleItems/target/items/item-1';

const liveItem = (extra = {}) => ({
  targetUid: 'target',
  createdByUid: 'planner',
  groupId: '',
  title: 'Wake up',
  status: 'approved',
  scheduledInstantUtc: new Date(SCHEDULED).toISOString(),
  alarm: { rangAt: new Date(SCHEDULED).toISOString() },
  ...extra,
});

// A db double with compare-and-set on updateTime that honours nested masks.
function harness(item, { tokens = ['planner-token'] } = {}) {
  const docs = {
    [PATH]: item,
    'users/target': { name: 'Test Target' },
    // Friendship is the planning permission; the push checks it live.
    'friendships/planner_target': { uids: ['planner', 'target'] },
  };
  let version = 1;
  const sent = [];
  const db = {
    getDoc: async (p) => docs[p] ?? null,
    getDocWithMeta: async (p) =>
      docs[p] ? { data: structuredClone(docs[p]), updateTime: String(version) } : null,
    patchDocIfUnchanged: async (p, fields, updateTime, maskPaths) => {
      if (String(version) !== updateTime) return false;
      const doc = structuredClone(docs[p]);
      for (const mask of maskPaths || Object.keys(fields)) {
        const keys = mask.split('.');
        let src = fields;
        let dst = doc;
        keys.forEach((k, i) => {
          if (i === keys.length - 1) {
            dst[k] = src[k];
          } else {
            dst[k] = dst[k] ?? {};
            dst = dst[k];
            src = src[k];
          }
        });
      }
      docs[p] = doc;
      version += 1;
      return true;
    },
    patchDoc: async (p, fields) => {
      docs[p] = { ...docs[p], ...fields };
      version += 1;
    },
    listDocIds: async () => tokens,
    deleteDoc: async () => {},
  };
  const fcm = {
    send: async (_t, message) => {
      sent.push(message);
      return { ok: true };
    },
  };
  return { docs, sent, ctx: { projectId: 'demo', db, fcm } };
}

test('a timeout a minute after the alarm time is accepted at the phone time', () => {
  const now = SCHEDULED + 70_000;
  const d = alarmTimeoutDecision(liveItem(), now, SCHEDULED + 60_000);
  assert.equal(d.ok, true);
  assert.equal(d.write, true);
  assert.equal(d.at.getTime(), SCHEDULED + 60_000);
});

test('the phone clock is clamped between the alarm time and now', () => {
  const now = SCHEDULED + 70_000;
  assert.equal(
    alarmTimeoutDecision(liveItem(), now, SCHEDULED - 3_600_000).at.getTime(),
    SCHEDULED,
  );
  assert.equal(
    alarmTimeoutDecision(liveItem(), now, now + 3_600_000).at.getTime(),
    now,
  );
  assert.equal(alarmTimeoutDecision(liveItem(), now, undefined).at.getTime(), now);
});

test('refused: early, stale, dismissed, cancelled, or missing', () => {
  const reason = (item, now) => alarmTimeoutDecision(item, now, now).reason;
  assert.equal(reason(liveItem(), SCHEDULED + MIN_AFTER_SCHEDULED_MS - 1), 'too-early');
  assert.equal(reason(liveItem(), SCHEDULED + MAX_AFTER_SCHEDULED_MS + 1), 'too-late');
  assert.equal(
    reason(liveItem({ alarm: { dismissedAt: '2030-01-01T09:00:20.000Z' } }), SCHEDULED + 70_000),
    'dismissed',
  );
  assert.equal(reason(liveItem({ status: 'withdrawn' }), SCHEDULED + 70_000), 'not-live');
  assert.equal(reason(null, SCHEDULED + 70_000), 'item-not-found');
});

test('an already recorded fact is not rewritten but the push may follow', () => {
  const item = liveItem({ alarm: { unavailableAt: '2030-01-01T09:01:00.000Z' } });
  const d = alarmTimeoutDecision(item, SCHEDULED + 90_000, SCHEDULED + 90_000);
  assert.deepEqual(d, { ok: true, write: false });
});

test('recording writes only alarm.unavailableAt and keeps rangAt', async () => {
  const h = harness(liveItem());
  const res = await recordAlarmTimeout(h.ctx.db, {
    targetUid: 'target',
    itemId: 'item-1',
    nowMs: SCHEDULED + 70_000,
    reportedAtMs: SCHEDULED + 60_000,
  });
  assert.deepEqual(res, { ready: true, recorded: true, reason: 'recorded' });
  assert.equal(h.docs[PATH].alarm.rangAt, new Date(SCHEDULED).toISOString());
  assert.equal(h.docs[PATH].alarm.unavailableAt.getTime(), SCHEDULED + 60_000);
});

test('the timeout reaches the planner at once, with the Uh-Oh channel', async () => {
  const h = harness(liveItem());
  const res = await alarmTimeoutAndNotify(h.ctx, {
    targetUid: 'target',
    itemId: 'item-1',
    nowMs: SCHEDULED + 70_000,
    reportedAtMs: SCHEDULED + 60_000,
  });
  assert.equal(res.recorded, true);
  assert.equal(res.sent, 1);
  assert.equal(res.recipientUid, 'planner');
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].android.notification.channel_id, 'planner_unavailable');
  assert.match(h.sent[0].notification.body, /Test Target was unavailable/);
});

test('a second report (native retry, then the app) pushes only once', async () => {
  const h = harness(liveItem());
  const args = {
    targetUid: 'target',
    itemId: 'item-1',
    nowMs: SCHEDULED + 70_000,
    reportedAtMs: SCHEDULED + 60_000,
  };
  await alarmTimeoutAndNotify(h.ctx, args);
  const again = await alarmTimeoutAndNotify(h.ctx, args);
  assert.equal(again.sent, 0);
  assert.equal(again.reason, 'already-notified');
  assert.equal(h.sent.length, 1);
});

test('a dismissed alarm never sends Uh-Oh', async () => {
  const h = harness(liveItem({ alarm: { dismissedAt: '2030-01-01T09:00:20.000Z' } }));
  const res = await alarmTimeoutAndNotify(h.ctx, {
    targetUid: 'target',
    itemId: 'item-1',
    nowMs: SCHEDULED + 70_000,
  });
  assert.equal(res.sent, 0);
  assert.equal(res.reason, 'dismissed');
  assert.equal(h.sent.length, 0);
});

test('a self-planned alarm records the fact but pushes nobody', async () => {
  const h = harness(liveItem({ createdByUid: 'target' }));
  const res = await alarmTimeoutAndNotify(h.ctx, {
    targetUid: 'target',
    itemId: 'item-1',
    nowMs: SCHEDULED + 70_000,
  });
  assert.equal(res.recorded, true);
  assert.equal(res.reason, 'self-planned');
  assert.equal(h.sent.length, 0);
});

test('the route checks the body before auth, and needs a token', async () => {
  const post = (payload) =>
    worker.fetch(
      new Request('https://worker.example/', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      }),
      { PROJECT_ID: 'demo-time-app' },
    );
  const bad = await post({ event: ALARM_TIMEOUT_EVENT, targetUid: 'a/b', itemId: 'x' });
  assert.equal(bad.status, 400);
  const noToken = await post({ event: ALARM_TIMEOUT_EVENT, targetUid: 'target', itemId: 'item-1' });
  assert.equal(noToken.status, 401);
});
