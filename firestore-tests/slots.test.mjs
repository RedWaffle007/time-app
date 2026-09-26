// Security-rules tests for the "view B's schedule" access mirror and the slot
// lock. Third world, separate from rules.test.mjs and social.test.mjs for the
// reason those two are separate from each other: a different seed.
//
// What is worth testing here is exactly what the client cannot enforce:
//
//   * group membership does not let someone read a non-friend's schedule, and
//     the retired plannerAccess rows / group grants no longer help (item 3);
//   * a slot lock is create-once — the second writer loses, which IS the
//     server-side conflict re-check;
//   * a lock cannot be stolen or overwritten, only released by the right people.
//
// Every denial is paired with the legitimate operation it must not break.
//
// Run: npm test

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { deleteDoc, doc, getDoc, setDoc, writeBatch } from 'firebase/firestore';

const TARGET = 'uidB';
const PLANNER = 'uidA';
const STRANGER = 'uidC';

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-slots',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});

after(async () => { await testEnv.cleanup(); });

const as = (uid) => testEnv.authenticatedContext(uid).firestore();

/** A retired planner-access hint row (item 3, 2026-09-27): it authorizes
 * nothing any more. */
async function seedAccess() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `plannerAccess/${PLANNER}_${TARGET}`), {
      plannerUid: PLANNER, targetUid: TARGET, groupId: 'g1', updatedAt: new Date(),
    });
  });
}

/** A retired group grant PLANNER->TARGET in g1 — inert since item 3. */
async function seedRetiredGrant() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `groups/g1/plannerGrants/${PLANNER}_${TARGET}`), {
      plannerUid: PLANNER, targetUid: TARGET, groupId: 'g1',
      granted: true, grantedByUid: TARGET,
    });
  });
}

/** PLANNER and TARGET are both members of g1 — what now lets a member put a
 * group plan (and its lock) on another member (item 3). */
async function seedGroup() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'groups/g1'), {
      name: 'G', ownerUid: TARGET, joinCode: 'SLOT23',
      memberUids: [TARGET, PLANNER],
    });
  });
}

async function seedItem() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `scheduleItems/${TARGET}/items/i1`), {
      targetUid: TARGET, createdByUid: TARGET, groupId: '', title: 'Gym',
      localWallTime: '', timezone: 'Asia/Kolkata',
      scheduledInstantUtc: new Date('2026-08-25T10:30:00Z'),
      status: 'approved', createdAt: new Date(), updatedAt: new Date(),
    });
  });
}

beforeEach(async () => { await testEnv.clearFirestore(); });

describe('reading the target schedule (item 3: friends only)', () => {
  const itemPath = `scheduleItems/${TARGET}/items/i1`;

  it('the target reads their own', async () => {
    await seedItem();
    await assertSucceeds(getDoc(doc(as(TARGET), itemPath)));
  });

  it('a fellow group member who is not a friend is denied — even holding a '
      + 'leftover grant AND hint row', async () => {
    await seedItem();
    await seedGroup();
    await seedRetiredGrant();
    await seedAccess();
    await assertFails(getDoc(doc(as(PLANNER), itemPath)));
  });

  it('a stranger is denied', async () => {
    await seedItem();
    await assertFails(getDoc(doc(as(STRANGER), itemPath)));
  });
});

describe('plannerAccess hint rows are retired (item 3)', () => {
  const rowPath = `plannerAccess/${PLANNER}_${TARGET}`;
  const row = { plannerUid: PLANNER, targetUid: TARGET, groupId: 'g1', updatedAt: new Date() };

  it('no one may write one any more', async () => {
    await seedGroup();
    await seedRetiredGrant();
    await assertFails(setDoc(doc(as(PLANNER), rowPath), row));
    await assertFails(setDoc(doc(as(TARGET), rowPath), row));
  });

  it('either party may read or delete a leftover; a stranger may not', async () => {
    await seedAccess();
    await assertFails(getDoc(doc(as(STRANGER), rowPath)));
    await assertSucceeds(getDoc(doc(as(PLANNER), rowPath)));
    await assertSucceeds(deleteDoc(doc(as(TARGET), rowPath)));
  });
});

describe('the slot lock — the server-side conflict re-check', () => {
  const SLOT = '999123';
  const lockPath = `scheduleSlots/${TARGET}/slots/${SLOT}`;

  const lock = (by) => ({
    targetUid: TARGET, createdByUid: by, groupId: 'g1', itemId: 'i1',
    createdAt: new Date(),
  });

  it('the target may claim a free slot', async () => {
    const db = testEnv.authenticatedContext(TARGET).firestore();
    await assertSucceeds(setDoc(doc(db, lockPath), lock(TARGET)));
  });

  it('a fellow group member may claim a free slot for a group plan', async () => {
    await seedGroup();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertSucceeds(setDoc(doc(db, lockPath), lock(PLANNER)));
  });

  it('a non-member cannot claim one, whatever leftovers they hold', async () => {
    await seedAccess();
    await seedRetiredGrant();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(setDoc(doc(db, lockPath), lock(PLANNER)));
  });

  it('THE RACE: the second writer loses', async () => {
    // This is the requirement. B books the slot while A's modal is open; A
    // submits against a stale view; A's write must be refused.
    await seedGroup();
    const target = testEnv.authenticatedContext(TARGET).firestore();
    await assertSucceeds(setDoc(doc(target, lockPath), lock(TARGET)));

    const planner = testEnv.authenticatedContext(PLANNER).firestore();
    // `set` on an existing doc is an UPDATE, and update is denied outright —
    // which is what turns this document into a lock rather than an upsert.
    await assertFails(setDoc(doc(planner, lockPath), lock(PLANNER)));
  });

  it('a lock cannot be overwritten even by the person who made it', async () => {
    const db = testEnv.authenticatedContext(TARGET).firestore();
    await assertSucceeds(setDoc(doc(db, lockPath), lock(TARGET)));
    await assertFails(setDoc(doc(db, lockPath), lock(TARGET)));
  });

  it('createdByUid cannot be forged', async () => {
    await seedGroup();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(setDoc(doc(db, lockPath), lock(TARGET)));
  });

  it('the batch is atomic: a taken slot blocks the ITEM too', async () => {
    // What `createItem` actually does. If the lock half fails, no item exists —
    // which is the property that makes this a real re-check rather than a UI
    // nicety.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), lockPath), lock(TARGET));
    });
    await seedGroup();

    const db = testEnv.authenticatedContext(PLANNER).firestore();
    const batch = writeBatch(db);
    batch.set(doc(db, lockPath), lock(PLANNER));
    batch.set(doc(db, `scheduleItems/${TARGET}/items/new1`), {
      targetUid: TARGET, createdByUid: PLANNER, groupId: 'g1', title: 'Clash',
      localWallTime: '', timezone: 'Asia/Kolkata',
      scheduledInstantUtc: new Date('2026-08-25T10:30:00Z'),
      status: 'pending', createdAt: new Date(), updatedAt: new Date(),
    });
    await assertFails(batch.commit());

    // And nothing landed.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const snap = await getDoc(doc(ctx.firestore(), `scheduleItems/${TARGET}/items/new1`));
      if (snap.exists()) throw new Error('item must not exist after a failed batch');
    });
  });

  it('releasing: the target and the lock owner may delete; nobody else', async () => {
    await seedGroup();
    const planner = testEnv.authenticatedContext(PLANNER).firestore();
    await assertSucceeds(setDoc(doc(planner, lockPath), lock(PLANNER)));

    const stranger = testEnv.authenticatedContext(STRANGER).firestore();
    await assertFails(deleteDoc(doc(stranger, lockPath)));

    // The planner made it, so the planner may free it (withdraw).
    await assertSucceeds(deleteDoc(doc(planner, lockPath)));

    // And the target may free one they did not make (reject).
    await assertSucceeds(setDoc(doc(planner, lockPath), lock(PLANNER)));
    const target = testEnv.authenticatedContext(TARGET).firestore();
    await assertSucceeds(deleteDoc(doc(target, lockPath)));
  });
});
