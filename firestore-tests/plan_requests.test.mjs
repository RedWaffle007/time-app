import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { doc, setDoc, updateDoc, writeBatch } from 'firebase/firestore';

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

async function seedGrant(granted = true) {
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

function item(itemId, start = '2030-11-03T06:00:00Z') {
  return {
    targetUid: TARGET,
    createdByUid: PLANNER,
    groupId: '',
    title: 'Morning plan',
    localWallTime: '2030-11-03T01:00',
    timezone: 'America/New_York',
    scheduledInstantUtc: new Date(start),
    durationMinutes: 30,
    planRequestId: REQUEST_ID,
    status: 'pending',
    createdAt: new Date(),
    updatedAt: new Date(),
  };
}

async function fulfill(db, itemId, {
  status = 'fulfilled',
  start = '2030-11-03T06:00:00Z',
  priorIds = [],
  priorSpans = [],
} = {}) {
  const nextSpan = {
    itemId,
    startUtc: new Date(start),
    durationMinutes: 30,
  };
  const batch = writeBatch(db);
  batch.set(doc(db, `scheduleItems/${TARGET}/items/${itemId}`),
    item(itemId, start));
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
  it('allows the target to ask a friend who already has a normal grant', async () => {
    await seedGrant();
    await assertSucceeds(setDoc(doc(as(TARGET), REQUEST_PATH), request()));
  });

  it('denies a request when the normal grant is absent or revoked', async () => {
    await assertFails(setDoc(doc(as(TARGET), REQUEST_PATH), request()));
    await seedGrant(false);
    await assertFails(setDoc(doc(as(TARGET), REQUEST_PATH), request()));
  });

  it('denies the planner creating an ask on the target behalf', async () => {
    await seedGrant();
    await assertFails(setDoc(doc(as(PLANNER), REQUEST_PATH), request()));
  });

  it('denies malformed bounds, duration, and deterministic id mismatch', async () => {
    await seedGrant();
    await assertFails(setDoc(doc(as(TARGET), REQUEST_PATH), request({
      windowEndUtc: new Date('2030-11-03T04:00:00Z'),
    })));
    await assertFails(setDoc(doc(as(TARGET), REQUEST_PATH), request({
      durationMinutes: 0,
    })));
    await assertFails(setDoc(doc(as(TARGET), 'planRequests/wrong'), request()));
  });
});

describe('fulfillment rechecks authority and lifecycle atomically', () => {
  it('creates a pending normal item and fulfills one-plan in one batch', async () => {
    await seedGrant();
    await seedRequest();
    await assertSucceeds(fulfill(as(PLANNER), 'item-1'));
  });

  it('the request alone grants no authority after grant revocation', async () => {
    await seedGrant(false);
    await seedRequest();
    await assertFails(fulfill(as(PLANNER), 'item-1'));
  });

  it('denies an item without the matching request update', async () => {
    await seedGrant();
    await seedRequest();
    await assertFails(setDoc(
      doc(as(PLANNER), `scheduleItems/${TARGET}/items/item-1`),
      item('item-1'),
    ));
  });

  it('denies fulfillment outside the absolute UTC window', async () => {
    await seedGrant();
    await seedRequest();
    await assertFails(fulfill(as(PLANNER), 'item-1', {
      start: '2030-11-03T08:45:00Z',
    }));
  });

  it('denies replay once the request is fulfilled', async () => {
    await seedGrant();
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
    await seedGrant();
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
    await seedGrant();
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
    await seedGrant();
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
