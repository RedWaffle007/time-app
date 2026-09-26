import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { deleteDoc, doc, setDoc, updateDoc, writeBatch } from 'firebase/firestore';

import { lockPath, plan } from './minute_lock.mjs';

const TARGET = 'target';
const PLANNER = 'planner';
const OUTSIDER = 'outsider';
const PAIR = 'planner_target';
const BATCH = 'request-batch';
const REQUEST_ID = `${BATCH}_${PLANNER}`;
const REQUEST_PATH = `planRequests/${REQUEST_ID}`;
const GRANT_PATH =
  `friendships/${PAIR}/plannerGrants/${PLANNER}_${TARGET}`;

let testEnv;
const as = (uid) => testEnv.authenticatedContext(uid).firestore();

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-planrequests',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(async () => testEnv.cleanup());

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of [TARGET, PLANNER, OUTSIDER]) {
      await setDoc(doc(db, 'users', uid), {
        name: uid,
        homeTimezone: 'America/New_York',
      });
    }
    await setDoc(doc(db, `friendships/${PAIR}`), {
      uidA: PLANNER,
      uidB: TARGET,
      participants: [PLANNER, TARGET],
      createdAt: new Date(),
    });
  });
});

const request = (overrides = {}) => ({
  batchId: BATCH,
  requesterUid: TARGET,
  plannerUid: PLANNER,
  participantUids: [TARGET, PLANNER],
  mode: 'onePlan',
  status: 'pending',
  timezone: 'America/New_York',
  windowStartUtc: new Date('2030-11-03T05:00:00Z'),
  windowEndUtc: new Date('2030-11-03T09:00:00Z'),
  durationMinutes: 30,
  title: 'Morning plan',
  message: 'Please pick a time',
  fulfilledSpans: [],
  fulfilledItemIds: [],
  createdAt: new Date(),
  updatedAt: new Date(),
  ...overrides,
});

/** The redesigned request (item 5): one minute, one-minute plan, a task. */
const newRequest = (overrides = {}) => request({
  windowStartUtc: new Date('2030-11-03T05:00:00Z'),
  windowEndUtc: new Date('2030-11-03T05:01:00Z'),
  durationMinutes: 1,
  title: 'Take medicine',
  message: 'After lunch',
  ...overrides,
});

async function unfriend() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await deleteDoc(doc(ctx.firestore(), `friendships/${PAIR}`));
  });
}

/** A pre-2026-09-27 friendship grant doc, now inert. */
async function seedRetiredGrant(granted = true) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), GRANT_PATH), {
      plannerUid: PLANNER,
      targetUid: TARGET,
      groupId: '',
      granted,
      grantedByUid: TARGET,
      updatedAt: new Date(),
    });
  });
}

async function seedRequest(overrides = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), REQUEST_PATH), request(overrides));
  });
}

function item(itemId, start = '2030-11-03T06:00:00Z', duration = 30, extra = {}) {
  return {
    targetUid: TARGET,
    createdByUid: PLANNER,
    groupId: '',
    title: 'Morning plan',
    localWallTime: '2030-11-03T01:00',
    timezone: 'America/New_York',
    scheduledInstantUtc: new Date(start),
    durationMinutes: duration,
    planRequestId: REQUEST_ID,
    status: 'pending',
    createdAt: new Date(),
    updatedAt: new Date(),
    ...extra,
  };
}

async function fulfill(db, itemId, {
  status = 'fulfilled',
  start = '2030-11-03T06:00:00Z',
  priorIds = [],
  priorSpans = [],
  duration = 30,
  extra = {},
} = {}) {
  const nextSpan = {
    itemId,
    startUtc: new Date(start),
    durationMinutes: duration,
  };
  const batch = writeBatch(db);
  batch.set(doc(db, `scheduleItems/${TARGET}/items/${itemId}`),
    item(itemId, start, duration, extra));
  // Item 4 (strict): the plan carries the lock on its minute.
  batch.set(doc(db, lockPath(TARGET, new Date(start))), {
    targetUid: TARGET, itemId, createdByUid: PLANNER, createdAt: new Date(),
  });
  batch.update(doc(db, REQUEST_PATH), {
    status,
    fulfilledSpans: [...priorSpans, nextSpan],
    fulfilledItemIds: [...priorIds, itemId],
    lastFulfilledItemId: itemId,
    ...(status === 'fulfilled' ? { settledByUid: PLANNER } : {}),
    updatedAt: new Date(),
  });
  return batch.commit();
}

describe('plan request creation is consent-scoped', () => {
  it('allows the target to ask a friend (friendship is the permission)', async () => {
    await assertSucceeds(setDoc(doc(as(TARGET), REQUEST_PATH), newRequest()));
  });

  it('denies a request to someone who is not a friend', async () => {
    await unfriend();
    await assertFails(setDoc(doc(as(TARGET), REQUEST_PATH), newRequest()));
  });

  it('a retired grant document with granted:false no longer matters', async () => {
    await seedRetiredGrant(false);
    await assertSucceeds(setDoc(doc(as(TARGET), REQUEST_PATH), newRequest()));
  });

  it('denies the planner creating an ask on the target behalf', async () => {
    await assertFails(setDoc(doc(as(PLANNER), REQUEST_PATH), newRequest()));
  });

  it('denies the old shapes: a window, a flexible request, a longer plan, no task', async () => {
    for (const bad of [
      { windowEndUtc: new Date('2030-11-03T09:00:00Z') },
      { mode: 'flexibleWindow' },
      { durationMinutes: 30 },
      { title: '   ' },
      { title: null },
    ]) {
      await assertFails(setDoc(doc(as(TARGET), REQUEST_PATH), newRequest(bad)),
        JSON.stringify(bad));
    }
  });

  it('denies malformed bounds, duration, and deterministic id mismatch', async () => {
    await assertFails(setDoc(doc(as(TARGET), REQUEST_PATH), newRequest({
      windowEndUtc: new Date('2030-11-03T04:00:00Z'),
    })));
    await assertFails(setDoc(doc(as(TARGET), REQUEST_PATH), newRequest({
      durationMinutes: 0,
    })));
    await assertFails(setDoc(doc(as(TARGET), 'planRequests/wrong'), newRequest()));
  });
});

describe('the redesigned request is fulfilled at exactly its minute', () => {
  it('the friend sets the alarm at the requested minute', async () => {
    await seedRequest(newRequest());
    await assertSucceeds(fulfill(as(PLANNER), 'item-1', {
      start: '2030-11-03T05:00:00Z', duration: 1,
    }));
  });

  it('DENIES a different minute', async () => {
    await seedRequest(newRequest());
    await assertFails(fulfill(as(PLANNER), 'item-1', {
      start: '2030-11-03T05:01:00Z', duration: 1,
    }));
  });

  it('DENIES it when the requester is already busy at that minute', async () => {
    await seedRequest(newRequest());
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await setDoc(doc(db, `scheduleItems/${TARGET}/items/busy`), {
        targetUid: TARGET, createdByUid: TARGET, groupId: '', title: 'Own',
        localWallTime: '', timezone: 'America/New_York',
        scheduledInstantUtc: new Date('2030-11-03T05:00:00Z'),
        status: 'approved', createdAt: new Date(), updatedAt: new Date(),
      });
      await setDoc(doc(db, lockPath(TARGET, new Date('2030-11-03T05:00:00Z'))), {
        targetUid: TARGET, itemId: 'busy', createdByUid: TARGET, createdAt: new Date(),
      });
    });
    await assertFails(fulfill(as(PLANNER), 'item-1', {
      start: '2030-11-03T05:00:00Z', duration: 1,
    }));
  });
});

describe('5b: fulfilled through the Plan screen — an alarm, voice note allowed', () => {
  it('an approved plan fulfils the request', async () => {
    await seedRequest(newRequest());
    await assertSucceeds(fulfill(as(PLANNER), 'item-1', {
      start: '2030-11-03T05:00:00Z', duration: 1,
      extra: { status: 'approved', decidedAt: new Date() },
    }));
  });

  it('a voice alarm fulfils it too, with the Worker-checked note', async () => {
    const sha = 'a'.repeat(64);
    await seedRequest(newRequest());
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'voiceUploads/voiceitem00000001'), {
        uploaderUid: PLANNER, targetUid: TARGET, sha256: sha,
        durationMs: 5000, sizeBytes: 40000,
      });
    });
    await assertSucceeds(fulfill(as(PLANNER), 'voiceitem00000001', {
      start: '2030-11-03T05:00:00Z', duration: 1,
      extra: {
        status: 'approved',
        title: 'Voice alarm',
        voiceNote: { durationMs: 5000, sha256: sha, sizeBytes: 40000 },
      },
    }));
  });

  it('DENIES a voice note the Worker did not check', async () => {
    await seedRequest(newRequest());
    await assertFails(fulfill(as(PLANNER), 'voiceitem00000002', {
      start: '2030-11-03T05:00:00Z', duration: 1,
      extra: {
        status: 'approved',
        voiceNote: { durationMs: 5000, sha256: 'b'.repeat(64), sizeBytes: 40000 },
      },
    }));
  });

  it('still refuses an unknown status', async () => {
    await seedRequest(newRequest());
    await assertFails(fulfill(as(PLANNER), 'item-9', {
      start: '2030-11-03T05:00:00Z', duration: 1,
      extra: { status: 'withdrawn' },
    }));
  });
});

describe('fulfillment rechecks authority and lifecycle atomically', () => {
  it('creates a pending normal item and fulfills one-plan in one batch', async () => {
    await seedRequest();
    await assertSucceeds(fulfill(as(PLANNER), 'item-1'));
  });

  it('the request alone grants no authority after unfriending', async () => {
    await seedRequest();
    await unfriend();
    await assertFails(fulfill(as(PLANNER), 'item-1'));
  });

  it('denies an item without the matching request update', async () => {
    await seedRequest();
    await assertFails(plan(as(PLANNER), `scheduleItems/${TARGET}/items/item-1`, item('item-1'),
    ));
  });

  it('denies fulfillment outside the absolute UTC window', async () => {
    await seedRequest();
    await assertFails(fulfill(as(PLANNER), 'item-1', {
      start: '2030-11-03T08:45:00Z',
    }));
  });

  it('denies replay once the request is fulfilled', async () => {
    await seedRequest({
      status: 'fulfilled',
      fulfilledSpans: [{
        itemId: 'old',
        startUtc: new Date('2030-11-03T06:00:00Z'),
        durationMinutes: 30,
      }],
      fulfilledItemIds: ['old'],
      lastFulfilledItemId: 'old',
      settledByUid: PLANNER,
    });
    await assertFails(fulfill(as(PLANNER), 'item-2'));
  });

  it('only the requester cancels and only the selected planner declines', async () => {
    await seedRequest();
    await assertFails(updateDoc(doc(as(OUTSIDER), REQUEST_PATH), {
      status: 'cancelled',
      settledByUid: OUTSIDER,
      updatedAt: new Date(),
    }));
    await assertSucceeds(updateDoc(doc(as(PLANNER), REQUEST_PATH), {
      status: 'declined',
      settledByUid: PLANNER,
      updatedAt: new Date(),
    }));
  });
});

describe('flexible requests accept multiple adjacent items', () => {
  it('keeps the request open, then closes it with a second item', async () => {
    await seedRequest({ mode: 'flexibleWindow' });
    const firstSpan = {
      itemId: 'item-1',
      startUtc: new Date('2030-11-03T06:00:00Z'),
      durationMinutes: 30,
    };
    await assertSucceeds(fulfill(as(PLANNER), 'item-1', {
      status: 'inProgress',
    }));
    await assertSucceeds(fulfill(as(PLANNER), 'item-2', {
      status: 'fulfilled',
      start: '2030-11-03T06:30:00Z',
      priorIds: ['item-1'],
      priorSpans: [firstSpan],
    }));
  });

  it('denies overlap with the previously appended span', async () => {
    const firstSpan = {
      itemId: 'item-1',
      startUtc: new Date('2030-11-03T06:00:00Z'),
      durationMinutes: 30,
    };
    await seedRequest({
      mode: 'flexibleWindow',
      status: 'inProgress',
      fulfilledSpans: [firstSpan],
      fulfilledItemIds: ['item-1'],
      lastFulfilledItemId: 'item-1',
    });
    await assertFails(fulfill(as(PLANNER), 'item-2', {
      status: 'fulfilled',
      start: '2030-11-03T06:15:00Z',
      priorIds: ['item-1'],
      priorSpans: [firstSpan],
    }));
  });
});
