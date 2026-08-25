// Regression tests for the two cross-device failures found on 2026-08-24.
// See DECISIONS.md "Cross-device relationship + planning denials (2026-08-24)".
// Run: npm test
//
// Bug 1 — username search spun forever. The `usernames/{handle}` get resolves;
//   the failure was downstream in profileVisibilityProvider, which listens to a
//   single-doc `friendships/{sortedPairId}` that does NOT exist for two
//   strangers. The rule denies that read (it dereferences a null resource), and
//   THAT IS CORRECT — allowing it would let anyone probe whether two other users
//   are friends. So this file still asserts the DENIAL; the fix is client-side
//   (relation_stream.dart maps this one denial to "absent"), which the rules
//   emulator cannot exercise. The test pins the rule behaviour the client relies
//   on so a future rule change that silently starts allowing it is caught.
//
// Bug 2 — planning cross-device was permission-denied. createItem commits ONE
//   atomic batch: a scheduleSlots lock + the item. The lock USED to require the
//   plannerAccess mirror (target-written, absent cross-device), which failed the
//   whole batch. The fix carries `groupId` on the lock and gates it on the SAME
//   active grant the item proves, so a real active grant with NO mirror now
//   SUCCEEDS, while no grant is still denied.

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, writeBatch } from 'firebase/firestore';

const PLANNER = 'uid_planner';
const TARGET = 'uid_target';
const pair = (a, b) => (a < b ? `${a}_${b}` : `${b}_${a}`);

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-repro',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(async () => { await testEnv.cleanup(); });
beforeEach(async () => { await testEnv.clearFirestore(); });

// --- Bug 1 ----------------------------------------------------------------

describe('Bug 1 — the stranger friendship read', () => {
  it('a signed-in user reading a NON-EXISTENT friendships/{pair} is DENIED', async () => {
    // No friendship seeded. This is watchFriendship(P, T) for two non-friends.
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(getDoc(doc(db, `friendships/${pair(PLANNER, TARGET)}`)));
  });

  it('contrast: a party reading an EXISTING friendship succeeds', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `friendships/${pair(PLANNER, TARGET)}`), {
        uidA: pair(PLANNER, TARGET).split('_')[0],
        uidB: pair(PLANNER, TARGET).split('_')[1],
        participants: [PLANNER, TARGET],
        createdAt: new Date(),
      });
    });
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertSucceeds(getDoc(doc(db, `friendships/${pair(PLANNER, TARGET)}`)));
  });
});

// --- Bug 2 ----------------------------------------------------------------

describe('Bug 2 — createItem batch with a grant but no plannerAccess mirror', () => {
  const SLOT = '999123';
  const lockPath = `scheduleSlots/${TARGET}/slots/${SLOT}`;
  const item = {
    targetUid: TARGET, createdByUid: PLANNER, groupId: 'g1', title: 'Plan',
    localWallTime: '', timezone: 'Asia/Kolkata',
    scheduledInstantUtc: new Date('2026-08-25T10:30:00Z'),
    status: 'pending', createdAt: new Date(), updatedAt: new Date(),
  };
  const lock = { targetUid: TARGET, createdByUid: PLANNER, groupId: 'g1', itemId: 'new1', createdAt: new Date() };

  async function seedGrant() {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `groups/g1/plannerGrants/${PLANNER}_${TARGET}`), {
        plannerUid: PLANNER, targetUid: TARGET, groupId: 'g1',
        granted: true, grantedByUid: TARGET,
      });
    });
  }
  async function seedMirror() {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `plannerAccess/${PLANNER}_${TARGET}`), {
        plannerUid: PLANNER, targetUid: TARGET, updatedAt: new Date(),
      });
    });
  }
  function commitBatch(db) {
    const batch = writeBatch(db);
    batch.set(doc(db, lockPath), lock);
    batch.set(doc(db, `scheduleItems/${TARGET}/items/new1`), item);
    return batch.commit();
  }

  it('THE FIX: active grant, NO mirror -> batch SUCCEEDS', async () => {
    await seedGrant();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertSucceeds(commitBatch(db));
  });

  it('no grant (mirror only) -> batch DENIED — a mirror is not a write grant', async () => {
    await seedMirror();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertFails(commitBatch(db));
  });

  it('with BOTH grant and mirror -> batch SUCCEEDS', async () => {
    await seedGrant();
    await seedMirror();
    const db = testEnv.authenticatedContext(PLANNER).firestore();
    await assertSucceeds(commitBatch(db));
  });
});
