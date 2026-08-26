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

const as = (uid) => testEnv.authenticatedContext(uid).firestore();

/** The planner's groupId HINT row. It only names a group — the read rule
 * re-checks the LIVE grant through it, so a row alone reads nothing (pair it
 * with seedGrant). */
async function seedAccess() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `plannerAccess/${PLANNER}_${TARGET}`), {
      plannerUid: PLANNER, targetUid: TARGET, groupId: 'g1', updatedAt: new Date(),
    });
  });
}

/** Flip the PLANNER->TARGET grant's `granted` flag, bypassing rules. */
async function setGranted(granted) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `groups/g1/plannerGrants/${PLANNER}_${TARGET}`),
      { granted }, { merge: true });
  });
}

/** An ACTIVE planner grant PLANNER->TARGET in group g1. This — not the mirror —
 * is what now authorises a planner to write a slot lock (see the create rule
 * for scheduleSlots and DECISIONS.md "Cross-device relationship + planning
 * denials"). */
async function seedGrant() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `groups/g1/plannerGrants/${PLANNER}_${TARGET}`), {
      plannerUid: PLANNER, targetUid: TARGET, groupId: 'g1',
      granted: true, grantedByUid: TARGET,
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
  const itemPath = `scheduleItems/${TARGET}/items/i1`;

  it('the target reads their own, with or without a mirror', async () => {
    await seedItem();
    await assertSucceeds(getDoc(doc(as(TARGET), itemPath)));
  });

  it('a planner with NO hint row is denied — even holding a grant', async () => {
    // The read carries no groupId, so the grant alone cannot authorize it; the
    // planner must have left a hint row. (Their reconciler writes one.)
    await seedItem();
    await seedGrant();
    await assertFails(getDoc(doc(as(PLANNER), itemPath)));
  });

  it('a planner WITH a hint row AND a live grant reads full detail', async () => {
    await seedItem();
    await seedGrant();
    await seedAccess();
    const snap = await assertSucceeds(getDoc(doc(as(PLANNER), itemPath)));
    // Full detail, not free/busy — the access model, not an oversight.
    if (snap.data().title !== 'Gym') throw new Error('title should be readable');
  });

  it('a hint row with NO backing grant reads nothing', async () => {
    // The row is only a hint; authorization is the live grant. A planner who
    // wrote a row but holds no grant is denied — the whole safety story.
    await seedItem();
    await seedAccess();
    await assertFails(getDoc(doc(as(PLANNER), itemPath)));
  });

  it('revoking the GRANT cuts the planner off, though the row remains', async () => {
    await seedItem();
    await seedGrant();
    await seedAccess();
    await assertSucceeds(getDoc(doc(as(PLANNER), itemPath)));
    await setGranted(false); // revoke — row is now a stale hint
    await assertFails(getDoc(doc(as(PLANNER), itemPath)));
  });

  it('a legacy row carrying no group reads nothing', async () => {
    await seedItem();
    await seedGrant();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `plannerAccess/${PLANNER}_${TARGET}`), {
        plannerUid: PLANNER, targetUid: TARGET, updatedAt: new Date(),
      });
    });
    await assertFails(getDoc(doc(as(PLANNER), itemPath)));
  });

  it('deleting the hint row also cuts the planner off', async () => {
    await seedItem();
    await seedGrant();
    await seedAccess();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await deleteDoc(doc(ctx.firestore(), `plannerAccess/${PLANNER}_${TARGET}`));
    });
    await assertFails(getDoc(doc(as(PLANNER), itemPath)));
  });

  it('a stranger is denied even while the planner is allowed', async () => {
    await seedItem();
    await seedGrant();
    await seedAccess();
    await assertFails(getDoc(doc(as(STRANGER), itemPath)));
  });

  it('read access does NOT confer write access to the target\'s items', async () => {
    await seedItem();
    await seedGrant();
    await seedAccess();
    // The planner did not create this item, so no write branch covers them.
    await assertFails(setDoc(doc(as(PLANNER), itemPath),
      { status: 'rejected' }, { merge: true }));
  });
});

describe('who may write the mirror hint', () => {
  const rowPath = `plannerAccess/${PLANNER}_${TARGET}`;
  const row = (overrides = {}) => ({
    plannerUid: PLANNER, targetUid: TARGET, groupId: 'g1',
    updatedAt: new Date(), ...overrides,
  });

  it('a PLANNER may self-provision, backed by a live grant', async () => {
    await seedGrant();
    await assertSucceeds(setDoc(doc(as(PLANNER), rowPath), row()));
  });

  it('a PLANNER cannot self-provision with NO grant', async () => {
    // No grant seeded: the row would be inert, and the rule refuses it outright.
    await assertFails(setDoc(doc(as(PLANNER), rowPath), row()));
  });

  it('a PLANNER cannot name a group they hold no grant in', async () => {
    await seedGrant(); // grant is in g1
    await assertFails(setDoc(doc(as(PLANNER), rowPath), row({ groupId: 'g2' })));
  });

  it('the target may still write their own row (back-compat)', async () => {
    await assertSucceeds(setDoc(doc(as(TARGET), rowPath), row()));
  });

  it('the id must match the contents, so a row cannot name someone else', async () => {
    await assertFails(setDoc(doc(as(TARGET), rowPath), row({ plannerUid: STRANGER })));
  });

  it('a target cannot forge a row over somebody else', async () => {
    await assertFails(setDoc(doc(as(TARGET), `plannerAccess/${PLANNER}_${STRANGER}`),
      row({ targetUid: STRANGER })));
  });

  it('the PLANNER may delete their own hint row (cleanup)', async () => {
    await seedAccess();
    await assertSucceeds(deleteDoc(doc(as(PLANNER), rowPath)));
  });

  it('the target may also delete the row', async () => {
    await seedAccess();
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

  it('a planner with an ACTIVE GRANT may claim a free slot — with NO mirror', async () => {
    // The regression guard for the cross-device planning denial: the lock is now
    // authorised by the grant the item also proves, not by the plannerAccess
    // mirror, so a planner can plan before the target's device has written it.
    await seedGrant();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertSucceeds(setDoc(doc(db, lockPath), lock(PLANNER)));
  });

  it('a planner WITHOUT a grant cannot claim one (a mirror is NOT enough)', async () => {
    // The mirror alone must not authorise a WRITE — only a read.
    await seedAccess();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(setDoc(doc(db, lockPath), lock(PLANNER)));
  });

  it('THE RACE: the second writer loses', async () => {
    // This is the requirement. B books the slot while A's modal is open; A
    // submits against a stale view; A's write must be refused.
    await seedGrant();
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
    await seedGrant();
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
    await seedGrant();

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
    await seedGrant();
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
