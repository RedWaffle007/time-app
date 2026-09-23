// Security-rules tests for FRIENDSHIP-scoped planning grants (#4) and the
// planning-permission request flow. A fourth world (its own seed): two friends
// A and B, an outsider C, and a self-planned item under A.
//
// What only the rules can enforce, and what these prove:
//   * a friendship grant is the TARGET's to give; a planner cannot mint one;
//   * only friends can grant / request; a non-friend is refused;
//   * the grant authorizes reads and pending item-creates DIRECTLY (computed
//     pair id, no plannerAccess hint row);
//   * the grant is VOID the instant the friendship ends (areFriends gate);
//   * a friend planner may create only a PENDING item, never approved;
//   * planningRequests: friends only, recipient decides once, either deletes.
//
// Run: npm test

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { deleteDoc, doc, getDoc, setDoc } from 'firebase/firestore';

const A = 'uidA'; // target — items live under A; A grants/receives requests
const B = 'uidB'; // planner — the friend who plans for A
const C = 'uidC'; // outsider — not friends with anyone

const sorted = (x, y) => (x < y ? `${x}_${y}` : `${y}_${x}`);
const PAIR = sorted(A, B); // friendship + grant subtree id
const GRANT = `${B}_${A}`; // plannerUid_targetUid
const grantPath = `friendships/${PAIR}/plannerGrants/${GRANT}`;
const GROUP = 'shared_group';
const groupGrantPath = `groups/${GROUP}/plannerGrants/${GRANT}`;
const itemPath = `scheduleItems/${A}/items/i1`;

let testEnv;

const as = (uid) => testEnv.authenticatedContext(uid).firestore();

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-friendgrants',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(async () => { await testEnv.cleanup(); });

async function seed() {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of [A, B, C]) {
      await setDoc(doc(db, 'users', uid), { name: uid, homeTimezone: 'Asia/Kolkata' });
    }
    // A and B are friends; C is nobody's friend.
    await setDoc(doc(db, 'friendships', PAIR), {
      uidA: A, uidB: B, participants: [A, B], createdAt: new Date(),
    });
    await setDoc(doc(db, 'groups', GROUP), {
      name: 'Shared group', ownerUid: A, joinCode: 'ABC234',
      memberUids: [A, B],
    });
    await setDoc(doc(db, `groups/${GROUP}/members/${A}`), { name: A });
    await setDoc(doc(db, `groups/${GROUP}/members/${B}`), { name: B });
    // A self-planned item under A (createdByUid A), so ONLY the friend-grant
    // read path can authorize B — not the "items I created" collection rule.
    await setDoc(doc(db, itemPath), {
      targetUid: A, createdByUid: A, groupId: '', title: 'Gym',
      localWallTime: '', timezone: 'Asia/Kolkata',
      scheduledInstantUtc: new Date('2026-08-25T10:30:00Z'),
      status: 'approved', createdAt: new Date(), updatedAt: new Date(),
    });
  });
}
beforeEach(seed);

/** A grants B the friendship planning grant, bypassing rules. */
async function seedGrant(granted = true) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), grantPath), {
      plannerUid: B, targetUid: A, groupId: '', granted, grantedByUid: A,
      updatedAt: new Date(),
    });
  });
}

async function seedLegacyGroupGrant() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, groupGrantPath), {
      plannerUid: B, targetUid: A, groupId: GROUP, granted: true,
      grantedByUid: A, updatedAt: new Date(),
    });
    await setDoc(doc(db, `plannerAccess/${B}_${A}`), {
      plannerUid: B, targetUid: A, groupId: GROUP, updatedAt: new Date(),
    });
  });
}

async function unfriend() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await deleteDoc(doc(ctx.firestore(), 'friendships', PAIR));
  });
}

describe('friendship planning grant — who may write it', () => {
  const grant = (o = {}) => ({
    plannerUid: B, targetUid: A, groupId: '', granted: true, grantedByUid: A,
    updatedAt: new Date(), ...o,
  });

  it('the TARGET may grant a friend', async () => {
    await assertSucceeds(setDoc(doc(as(A), grantPath), grant()));
  });

  it('a PLANNER cannot mint a grant over the target', async () => {
    // B would need targetUid == A, but the rule pins targetUid to the caller.
    await assertFails(setDoc(doc(as(B), grantPath), grant()));
  });

  it('a non-friend cannot be granted', async () => {
    // A grants C, but they are not friends.
    const pairAC = sorted(A, C);
    await assertFails(setDoc(
      doc(as(A), `friendships/${pairAC}/plannerGrants/${C}_${A}`),
      grant({ plannerUid: C })));
  });

  it('a non-empty groupId is refused (friend grants carry no group)', async () => {
    await assertFails(setDoc(doc(as(A), grantPath), grant({ groupId: 'g1' })));
  });

  it('the planner may relinquish their own grant to false', async () => {
    await seedGrant(true);
    await assertSucceeds(setDoc(doc(as(B), grantPath),
      { granted: false, updatedAt: new Date() }, { merge: true }));
  });

  it('the planner cannot turn their own grant ON', async () => {
    await seedGrant(false);
    await assertFails(setDoc(doc(as(B), grantPath),
      { granted: true, updatedAt: new Date() }, { merge: true }));
  });
});

describe('friendship planning grant — what it authorizes', () => {
  it('a granted friend reads the target schedule', async () => {
    await seedGrant();
    const snap = await assertSucceeds(getDoc(doc(as(B), itemPath)));
    if (snap.data().title !== 'Gym') throw new Error('title should be readable');
  });

  it('without a grant, a friend is denied', async () => {
    await assertFails(getDoc(doc(as(B), itemPath)));
  });

  it('a revoked grant reads nothing', async () => {
    await seedGrant(false);
    await assertFails(getDoc(doc(as(B), itemPath)));
  });

  it('unfriending voids the grant even though the grant doc remains', async () => {
    await seedGrant(true);
    await assertSucceeds(getDoc(doc(as(B), itemPath)));
    await unfriend();
    await assertFails(getDoc(doc(as(B), itemPath)));
  });

  it('a granted friend may create a PENDING item', async () => {
    await seedGrant();
    await assertSucceeds(setDoc(doc(as(B), `scheduleItems/${A}/items/new1`), {
      targetUid: A, createdByUid: B, groupId: '', title: 'Study',
      localWallTime: '2026-08-25 19:00', timezone: 'Asia/Kolkata',
      scheduledInstantUtc: new Date('2026-08-25T13:30:00Z'),
      status: 'pending', createdAt: new Date(), updatedAt: new Date(),
    }));
  });

  it('a granted friend may NOT create an already-approved item', async () => {
    await seedGrant();
    await assertFails(setDoc(doc(as(B), `scheduleItems/${A}/items/new2`), {
      targetUid: A, createdByUid: B, groupId: '', title: 'Study',
      localWallTime: '2026-08-25 19:00', timezone: 'Asia/Kolkata',
      scheduledInstantUtc: new Date('2026-08-25T13:30:00Z'),
      status: 'approved', createdAt: new Date(), updatedAt: new Date(),
    }));
  });

  it('a granted friend may claim a slot lock', async () => {
    await seedGrant();
    await assertSucceeds(setDoc(doc(as(B), `scheduleSlots/${A}/slots/999`), {
      targetUid: A, createdByUid: B, groupId: '', itemId: 'new1',
      createdAt: new Date(),
    }));
  });
});

describe('friends use profile permission, never group permission', () => {
  it('DENIES creating a group grant between friends', async () => {
    await assertFails(setDoc(doc(as(A), groupGrantPath), {
      plannerUid: B, targetUid: A, groupId: GROUP, granted: true,
      grantedByUid: A, updatedAt: new Date(),
    }));
  });

  it('a legacy group grant is inert once the pair are friends', async () => {
    await seedLegacyGroupGrant();
    await assertFails(getDoc(doc(as(B), itemPath)));
  });

  it('allows the target to revoke a legacy group grant during migration', async () => {
    await seedLegacyGroupGrant();
    await assertSucceeds(setDoc(doc(as(A), groupGrantPath), {
      granted: false, updatedAt: new Date(),
    }, { merge: true }));
  });
});

describe('planning-permission requests', () => {
  const reqPath = `planningRequests/${B}_${A}_normal`;
  const req = (o = {}) => ({
    fromUid: B, toUid: A, kind: 'normal', participants: [B, A],
    status: 'pending', createdAt: new Date(), updatedAt: new Date(), ...o,
  });

  it('a friend may request planning permission', async () => {
    await assertSucceeds(setDoc(doc(as(B), reqPath), req()));
  });

  it('a non-friend may not request', async () => {
    const p = `planningRequests/${C}_${A}_normal`;
    await assertFails(setDoc(doc(as(C), p), req({ fromUid: C, participants: [C, A] })));
  });

  it('the id must encode from_to_kind', async () => {
    await assertFails(setDoc(doc(as(B), `planningRequests/${B}_${A}_normal`),
      req({ kind: 'emergency' }))); // kind mismatch vs id
  });

  it('the recipient may approve; the sender may not', async () => {
    await setDoc(doc(as(B), reqPath), req());
    await assertFails(setDoc(doc(as(B), reqPath),
      { status: 'approved', updatedAt: new Date() }, { merge: true }));
    await assertSucceeds(setDoc(doc(as(A), reqPath),
      { status: 'approved', decidedAt: new Date(), updatedAt: new Date() },
      { merge: true }));
  });

  it('either party may delete the request', async () => {
    await setDoc(doc(as(B), reqPath), req());
    await assertSucceeds(deleteDoc(doc(as(A), reqPath)));
  });
});

// --- Emergency tier (#5) ---------------------------------------------------
const emgPath = `friendships/${PAIR}/emergencyGrants/${GRANT}`;

async function seedEmergencyGrant(granted = true) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), emgPath), {
      plannerUid: B, targetUid: A, groupId: '', granted, grantedByUid: A,
      updatedAt: new Date(),
    });
  });
}

const emgItem = (o = {}) => ({
  targetUid: A, createdByUid: B, groupId: '', title: 'Take meds',
  localWallTime: '2026-08-25 19:00', timezone: 'Asia/Kolkata',
  scheduledInstantUtc: new Date('2026-08-25T13:30:00Z'),
  tier: 'emergency', status: 'approved',
  createdAt: new Date(), updatedAt: new Date(), ...o,
});

describe('emergency grant — who may write it', () => {
  const g = (o = {}) => ({
    plannerUid: B, targetUid: A, groupId: '', granted: true, grantedByUid: A,
    updatedAt: new Date(), ...o,
  });
  it('the TARGET may grant emergency', async () => {
    await assertSucceeds(setDoc(doc(as(A), emgPath), g()));
  });
  it('a PLANNER cannot mint an emergency grant', async () => {
    await assertFails(setDoc(doc(as(B), emgPath), g()));
  });
  it('a non-friend cannot be emergency-granted', async () => {
    const pairAC = sorted(A, C);
    await assertFails(setDoc(
      doc(as(A), `friendships/${pairAC}/emergencyGrants/${C}_${A}`),
      g({ plannerUid: C })));
  });
});

describe('emergency tier — the both-way invariant', () => {
  it('a NORMAL grant CANNOT create an emergency item', async () => {
    await seedGrant(true); // normal only
    await assertFails(setDoc(doc(as(B), `scheduleItems/${A}/items/e1`), emgItem()));
  });

  it('an EMERGENCY grant CANNOT create a normal PENDING item', async () => {
    await seedEmergencyGrant(true); // emergency only, no normal grant
    await assertFails(setDoc(doc(as(B), `scheduleItems/${A}/items/n1`),
      emgItem({ tier: 'normal', status: 'pending' })));
  });

  it('an EMERGENCY grant CANNOT create a normal APPROVED item', async () => {
    await seedEmergencyGrant(true);
    await assertFails(setDoc(doc(as(B), `scheduleItems/${A}/items/n2`),
      emgItem({ tier: 'normal', status: 'approved' })));
  });

  it('an EMERGENCY grant creates an approved emergency item', async () => {
    await seedEmergencyGrant(true);
    await assertSucceeds(setDoc(doc(as(B), `scheduleItems/${A}/items/e2`), emgItem()));
  });

  it('an emergency item CANNOT be born pending (must be approved)', async () => {
    await seedEmergencyGrant(true);
    await assertFails(setDoc(doc(as(B), `scheduleItems/${A}/items/e3`),
      emgItem({ status: 'pending' })));
  });

  it('unfriending voids the emergency grant', async () => {
    await seedEmergencyGrant(true);
    await unfriend();
    await assertFails(setDoc(doc(as(B), `scheduleItems/${A}/items/e4`), emgItem()));
  });
});

describe('emergency tier — read + recall', () => {
  it('an emergency grant authorizes reading the schedule', async () => {
    await seedEmergencyGrant(true);
    await assertSucceeds(getDoc(doc(as(B), itemPath)));
  });

  it('the creator may recall (withdraw) their approved emergency item', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `scheduleItems/${A}/items/e5`), emgItem());
    });
    await assertSucceeds(setDoc(doc(as(B), `scheduleItems/${A}/items/e5`),
      { status: 'withdrawn', withdrawnAt: new Date(), updatedAt: new Date() },
      { merge: true }));
  });

  it('the creator may NOT withdraw an approved NORMAL item', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `scheduleItems/${A}/items/e6`),
        emgItem({ tier: 'normal', status: 'approved' }));
    });
    await assertFails(setDoc(doc(as(B), `scheduleItems/${A}/items/e6`),
      { status: 'withdrawn', withdrawnAt: new Date(), updatedAt: new Date() },
      { merge: true }));
  });
});

describe('emergency planning requests', () => {
  it('a friend may request emergency permission (kind in the id)', async () => {
    await assertSucceeds(setDoc(doc(as(B), `planningRequests/${B}_${A}_emergency`), {
      fromUid: B, toUid: A, kind: 'emergency', participants: [B, A],
      status: 'pending', createdAt: new Date(), updatedAt: new Date(),
    }));
  });
});
