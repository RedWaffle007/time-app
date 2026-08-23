// Security-rules tests for the "view B's schedule" access mirror and the slot
// lock. Third world, separate from rules.test.mjs and social.test.mjs for the
// reason those two are separate from each other: a different seed.
//
// What is worth testing here is exactly what the client cannot enforce:
//
//   * a planner cannot read a schedule without a plannerAccess row;
//   * a planner cannot MINT their own row (the whole model inverted);
//   * the row's id must match its contents, so it cannot name someone else;
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

/** The mirror row that grants PLANNER read access over TARGET. */
async function seedAccess() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `plannerAccess/${PLANNER}_${TARGET}`), {
      plannerUid: PLANNER, targetUid: TARGET, updatedAt: new Date(),
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

describe('reading the target schedule', () => {
  it('the target reads their own, with or without a mirror', async () => {
    await seedItem();
    const db = testEnv.authenticatedContext(TARGET).firestore();
    await assertSucceeds(getDoc(doc(db, `scheduleItems/${TARGET}/items/i1`)));
  });

  it('a planner with NO mirror row is denied — this is the pre-feature state', async () => {
    await seedItem();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(getDoc(doc(db, `scheduleItems/${TARGET}/items/i1`)));
  });

  it('a planner WITH a mirror row reads full detail', async () => {
    await seedItem();
    await seedAccess();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    const snap = await assertSucceeds(
      getDoc(doc(db, `scheduleItems/${TARGET}/items/i1`)));
    // Full detail, not free/busy — the access model, not an oversight.
    if (snap.data().title !== 'Gym') throw new Error('title should be readable');
  });

  it('a stranger is denied even while the planner is allowed', async () => {
    await seedItem();
    await seedAccess();
    const db = testEnv.authenticatedContext(STRANGER).firestore();
    await assertFails(getDoc(doc(db, `scheduleItems/${TARGET}/items/i1`)));
  });

  it('revoking the mirror cuts the planner off again', async () => {
    await seedItem();
    await seedAccess();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await deleteDoc(doc(ctx.firestore(), `plannerAccess/${PLANNER}_${TARGET}`));
    });
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(getDoc(doc(db, `scheduleItems/${TARGET}/items/i1`)));
  });

  it('read access does NOT confer write access to the target\'s items', async () => {
    await seedItem();
    await seedAccess();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    // The planner did not create this item, so no write branch covers them.
    await assertFails(setDoc(doc(db, `scheduleItems/${TARGET}/items/i1`),
      { status: 'rejected' }, { merge: true }));
  });
});

describe('who may write the mirror', () => {
  it('the target may create their own row', async () => {
    const db = testEnv.authenticatedContext(TARGET).firestore();
    await assertSucceeds(setDoc(doc(db, `plannerAccess/${PLANNER}_${TARGET}`), {
      plannerUid: PLANNER, targetUid: TARGET, updatedAt: new Date(),
    }));
  });

  it('a PLANNER cannot mint their own access — the model inverted', async () => {
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(setDoc(doc(db, `plannerAccess/${PLANNER}_${TARGET}`), {
      plannerUid: PLANNER, targetUid: TARGET, updatedAt: new Date(),
    }));
  });

  it('the id must match the contents, so a row cannot name someone else', async () => {
    const db = testEnv.authenticatedContext(TARGET).firestore();
    await assertFails(setDoc(doc(db, `${'plannerAccess'}/${PLANNER}_${TARGET}`), {
      plannerUid: STRANGER, targetUid: TARGET, updatedAt: new Date(),
    }));
  });

  it('a target cannot forge a row over somebody else', async () => {
    const db = testEnv.authenticatedContext(TARGET).firestore();
    await assertFails(setDoc(doc(db, `plannerAccess/${PLANNER}_${STRANGER}`), {
      plannerUid: PLANNER, targetUid: STRANGER, updatedAt: new Date(),
    }));
  });

  it('only the target may delete the row', async () => {
    await seedAccess();
    const planner = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(deleteDoc(doc(planner, `plannerAccess/${PLANNER}_${TARGET}`)));
    const target = testEnv.authenticatedContext(TARGET).firestore();
    await assertSucceeds(deleteDoc(doc(target, `plannerAccess/${PLANNER}_${TARGET}`)));
  });
});

describe('the slot lock — the server-side conflict re-check', () => {
  const SLOT = '999123';
  const lockPath = `scheduleSlots/${TARGET}/slots/${SLOT}`;

  const lock = (by) => ({
    targetUid: TARGET, createdByUid: by, itemId: 'i1', createdAt: new Date(),
  });

  it('the target may claim a free slot', async () => {
    const db = testEnv.authenticatedContext(TARGET).firestore();
    await assertSucceeds(setDoc(doc(db, lockPath), lock(TARGET)));
  });

  it('a planner with access may claim a free slot', async () => {
    await seedAccess();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertSucceeds(setDoc(doc(db, lockPath), lock(PLANNER)));
  });

  it('a planner WITHOUT access cannot claim one', async () => {
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(setDoc(doc(db, lockPath), lock(PLANNER)));
  });

  it('THE RACE: the second writer loses', async () => {
    // This is the requirement. B books the slot while A's modal is open; A
    // submits against a stale view; A's write must be refused.
    await seedAccess();
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
    await seedAccess();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(setDoc(doc(db, lockPath), lock(TARGET)));
  });

  it('the batch is atomic: a taken slot blocks the ITEM too', async () => {
    // What `createItem` actually does. If the lock half fails, no item exists —
    // which is the property that makes this a real re-check rather than a UI
    // nicety.
    await seedAccess();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), lockPath), lock(TARGET));
    });
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `groups/g1/plannerGrants/${PLANNER}_${TARGET}`), {
        plannerUid: PLANNER, targetUid: TARGET, groupId: 'g1',
        granted: true, grantedByUid: TARGET,
      });
    });

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
    await seedAccess();
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
