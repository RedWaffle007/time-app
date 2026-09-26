// Security-rules tests for Batch G item 4 — no double-booking, strict.
// DECISIONS.md "No double-booking — minute locks".
//
// World: friends A (target) and B, an outsider C, a group G of A, B and D
// (D is not A's friend), and nothing planned yet.
//
// What only the rules can enforce, and what these prove:
//   * an item cannot be created without the lock on ITS minute;
//   * a minute held by a LIVE plan cannot be taken — self-plans included;
//   * a minute whose plan is settled / cancelled can be taken over;
//   * the target may backfill locks for their own live plans;
//   * only the target and friends may read a lock; nobody deletes one.
//
// Run: npm test

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  setDoc,
  writeBatch,
} from 'firebase/firestore';

import { lockPath, plan } from './minute_lock.mjs';

const A = 'uidA'; // target
const B = 'uidB'; // A's friend
const C = 'uidC'; // outsider
const D = 'uidD'; // in A's group, not A's friend
const GROUP = 'g1';
const SIX_PM = new Date('2030-10-05T01:00:00Z'); // 18:00 Vancouver (PDT)

let testEnv;
const as = (uid) => testEnv.authenticatedContext(uid).firestore();

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-minutelocks',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(async () => { await testEnv.cleanup(); });

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of [A, B, C, D]) {
      await setDoc(doc(db, 'users', uid), { name: uid, homeTimezone: 'America/Vancouver' });
    }
    await setDoc(doc(db, 'friendships', `${A}_${B}`), {
      uidA: A, uidB: B, participants: [A, B], createdAt: new Date(),
    });
    await setDoc(doc(db, 'groups', GROUP), {
      name: 'G', ownerUid: A, joinCode: 'LOCK23', memberUids: [A, B, D],
    });
  });
});

const alarm = (o = {}) => ({
  targetUid: A, createdByUid: B, groupId: '', title: 'Study',
  localWallTime: '2030-10-04T18:00', timezone: 'America/Vancouver',
  scheduledInstantUtc: SIX_PM, status: 'approved',
  createdAt: new Date(), updatedAt: new Date(), ...o,
});
const item = (id) => `scheduleItems/${A}/items/${id}`;

async function seedPlan(id, o = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const data = alarm(o);
    await setDoc(doc(db, item(id)), data);
    await setDoc(doc(db, lockPath(A, data.scheduledInstantUtc)), {
      targetUid: A, itemId: id, createdByUid: data.createdByUid, createdAt: new Date(),
    });
  });
}

describe('every plan brings its minute lock', () => {
  it('a friend\'s plan with its lock is created', async () => {
    await assertSucceeds(plan(as(B), item('p1'), alarm()));
  });

  it('DENIES a plan without a lock', async () => {
    await assertFails(setDoc(doc(as(B), item('p2')), alarm()));
  });

  it('DENIES a lock at the wrong minute, or naming another item', async () => {
    const db = as(B);
    const wrongMinute = writeBatch(db);
    wrongMinute.set(doc(db, item('p3')), alarm());
    wrongMinute.set(doc(db, lockPath(A, new Date('2030-10-05T01:01:00Z'))), {
      targetUid: A, itemId: 'p3', createdByUid: B, createdAt: new Date(),
    });
    await assertFails(wrongMinute.commit());

    const wrongItem = writeBatch(db);
    wrongItem.set(doc(db, item('p4')), alarm());
    wrongItem.set(doc(db, lockPath(A, SIX_PM)), {
      targetUid: A, itemId: 'someone-else', createdByUid: B, createdAt: new Date(),
    });
    await assertFails(wrongItem.commit());
  });
});

describe('a live plan holds its minute', () => {
  it('DENIES a second plan at the same minute — by a friend', async () => {
    await seedPlan('held');
    await assertFails(plan(as(B), item('p5'), alarm()));
  });

  it('DENIES a SELF-plan at a minute someone else already planned', async () => {
    await seedPlan('held');
    await assertFails(plan(as(A), item('p6'), alarm({ createdByUid: A })));
  });

  it('DENIES a group plan at a held minute', async () => {
    await seedPlan('held');
    await assertFails(plan(as(D), item('p7'), alarm({ createdByUid: D, groupId: GROUP })));
  });

  it('one minute later is free', async () => {
    await seedPlan('held');
    await assertSucceeds(plan(as(B), item('p8'), alarm({
      scheduledInstantUtc: new Date('2030-10-05T01:01:00Z'),
    })));
  });

  it('a pending (older client) plan holds its minute too', async () => {
    await seedPlan('held', { status: 'pending' });
    await assertFails(plan(as(B), item('p9'), alarm()));
  });
});

describe('a settled plan frees its minute — no release step', () => {
  for (const [name, o] of [
    ['done', { outcome: { result: 'done' } }],
    ['skipped', { outcome: { result: 'skipped' } }],
    ['cancelled by the planner', { status: 'withdrawn' }],
    ['rejected', { status: 'rejected' }],
    ['cancelled', { status: 'cancelled' }],
  ]) {
    it(`takes over a minute whose plan was ${name}`, async () => {
      await seedPlan('old', o);
      await assertSucceeds(plan(as(B), item('p10'), alarm()));
    });
  }

  it('takes over a lock whose plan no longer exists', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), lockPath(A, SIX_PM)), {
        targetUid: A, itemId: 'gone', createdByUid: B, createdAt: new Date(),
      });
    });
    await assertSucceeds(plan(as(B), item('p11'), alarm()));
  });
});

describe('who may plan (unchanged by locks)', () => {
  it('a fellow group member plans a group-tagged alarm at a free minute', async () => {
    await assertSucceeds(plan(as(D), item('g1'), alarm({ createdByUid: D, groupId: GROUP })));
  });

  it('DENIES an outsider even with a well-formed lock', async () => {
    await assertFails(plan(as(C), item('c1'), alarm({ createdByUid: C })));
  });

  it('DENIES a lock claiming someone else wrote it', async () => {
    const db = as(B);
    const batch = writeBatch(db);
    batch.set(doc(db, item('p12')), alarm());
    batch.set(doc(db, lockPath(A, SIX_PM)), {
      targetUid: A, itemId: 'p12', createdByUid: A, createdAt: new Date(),
    });
    await assertFails(batch.commit());
  });
});

describe('backfill — the target locks their own older plans', () => {
  async function seedUnlocked(id, o = {}) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), item(id)), alarm(o));
    });
  }
  const lockFor = (id, by) => ({ targetUid: A, itemId: id, createdByUid: by, createdAt: new Date() });

  it('the target locks a live plan someone else made before locks existed', async () => {
    await seedUnlocked('legacy');
    await assertSucceeds(setDoc(doc(as(A), lockPath(A, SIX_PM)), lockFor('legacy', A)));
    // …and from then on it blocks a clash.
    await assertFails(plan(as(B), item('p13'), alarm()));
  });

  it('DENIES backfilling a settled plan, or at the wrong minute', async () => {
    await seedUnlocked('settled', { outcome: { result: 'done' } });
    await assertFails(setDoc(doc(as(A), lockPath(A, SIX_PM)), lockFor('settled', A)));
    await seedUnlocked('live');
    await assertFails(setDoc(
      doc(as(A), lockPath(A, new Date('2030-10-05T02:00:00Z'))), lockFor('live', A)));
  });

  it('DENIES an outsider backfilling someone else\'s plan', async () => {
    await seedUnlocked('legacy');
    await assertFails(setDoc(doc(as(C), lockPath(A, SIX_PM)), lockFor('legacy', C)));
  });

  it('DENIES re-pointing a held lock while its plan is live', async () => {
    await seedPlan('held');
    await seedUnlocked('other', { scheduledInstantUtc: SIX_PM });
    await assertFails(setDoc(doc(as(A), lockPath(A, SIX_PM)), lockFor('other', A)));
  });
});

describe('reading and deleting locks', () => {
  it('the target and a friend may read one; a group member or outsider may not', async () => {
    await seedPlan('held');
    const path = lockPath(A, SIX_PM);
    await assertSucceeds(getDoc(doc(as(A), path)));
    await assertSucceeds(getDoc(doc(as(B), path)));
    await assertFails(getDoc(doc(as(D), path)));
    await assertFails(getDoc(doc(as(C), path)));
  });

  it('only the target may list their locks', async () => {
    await seedPlan('held');
    await assertSucceeds(getDocs(collection(as(A), `scheduleMinutes/${A}/minutes`)));
    await assertFails(getDocs(collection(as(B), `scheduleMinutes/${A}/minutes`)));
  });

  it('nobody deletes a lock', async () => {
    await seedPlan('held');
    await assertFails(deleteDoc(doc(as(A), lockPath(A, SIX_PM))));
    await assertFails(deleteDoc(doc(as(B), lockPath(A, SIX_PM))));
  });
});

describe('DST: the repeated hour is two different minutes', () => {
  it('01:30 PDT and 01:30 PST on the fall-back night can both be planned', async () => {
    await assertSucceeds(plan(as(B), item('d1'), alarm({
      scheduledInstantUtc: new Date('2030-11-03T08:30:00Z'),
    })));
    await assertSucceeds(plan(as(B), item('d2'), alarm({
      scheduledInstantUtc: new Date('2030-11-03T09:30:00Z'),
    })));
  });
});
