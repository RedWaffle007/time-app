// Security-rules tests for "friendship IS the planning permission" (Batch G
// item 2, 2026-09-27; DECISIONS.md "Friendship is the planning permission").
// Replaces the per-direction friendship grants, the merged emergency grant
// and the planning-permission requests.
//
// World: friends A and B, an outsider C, a group both friends belong to, and
// a self-planned item under A.
//
// What only the rules can enforce, and what these prove:
//   * a friend may read A's schedule and set alarms for A with NO grant doc;
//   * unfriending or blocking (which removes the friendship) ends both at once;
//   * a non-friend is denied;
//   * the retired grant / request documents can no longer be written, but the
//     parties may still read and delete leftovers;
//   * a non-friend co-member may only set GROUP-tagged alarms (item 3).
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

import { plan } from './minute_lock.mjs';

const A = 'uidA'; // target — items live under A
const B = 'uidB'; // planner — A's friend
const C = 'uidC'; // outsider — nobody's friend

const sorted = (x, y) => (x < y ? `${x}_${y}` : `${y}_${x}`);
const PAIR = sorted(A, B);
const GRANT = `${B}_${A}`; // plannerUid_targetUid
const GROUP = 'shared_group';
const itemPath = `scheduleItems/${A}/items/i1`;

let testEnv;

const as = (uid) => testEnv.authenticatedContext(uid).firestore();

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-friendpermission',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(async () => { await testEnv.cleanup(); });

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of [A, B, C]) {
      await setDoc(doc(db, 'users', uid), { name: uid, homeTimezone: 'Asia/Kolkata' });
    }
    await setDoc(doc(db, 'friendships', PAIR), {
      uidA: A, uidB: B, participants: [A, B], createdAt: new Date(),
    });
    await setDoc(doc(db, 'groups', GROUP), {
      name: 'Shared group', ownerUid: A, joinCode: 'ABC234',
      memberUids: [A, B, C],
    });
    for (const uid of [A, B, C]) {
      await setDoc(doc(db, `groups/${GROUP}/members/${uid}`), { name: uid });
    }
    // Self-planned by A, so ONLY the friendship path can let B read it (not
    // the "items I created" collection-group rule).
    await setDoc(doc(db, itemPath), {
      targetUid: A, createdByUid: A, groupId: '', title: 'Gym',
      localWallTime: '', timezone: 'Asia/Kolkata',
      scheduledInstantUtc: new Date('2026-08-25T10:30:00Z'),
      status: 'approved', createdAt: new Date(), updatedAt: new Date(),
    });
  });
});

async function unfriend() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await deleteDoc(doc(ctx.firestore(), 'friendships', PAIR));
  });
}

async function seedRetired(path, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), path), data);
  });
}

const alarm = (o = {}) => ({
  targetUid: A, createdByUid: B, groupId: '', title: 'Study',
  localWallTime: '2026-08-25 19:00', timezone: 'Asia/Kolkata',
  scheduledInstantUtc: new Date('2026-08-25T13:30:00Z'),
  status: 'approved', createdAt: new Date(), updatedAt: new Date(), ...o,
});

describe('a friend needs no grant', () => {
  it('reads the friend schedule', async () => {
    const snap = await assertSucceeds(getDoc(doc(as(B), itemPath)));
    if (snap.data().title !== 'Gym') throw new Error('title should be readable');
  });

  it('sets an alarm that rings directly (approved)', async () => {
    await assertSucceeds(plan(as(B), `scheduleItems/${A}/items/n1`, alarm()));
  });

  it('an older client may still write pending or emergency-tier items', async () => {
    await assertSucceeds(plan(as(B), `scheduleItems/${A}/items/n2`, alarm({ status: 'pending' })));
    // A different minute: n2 holds 13:30 now (item 4, no double-booking).
    await assertSucceeds(plan(as(B), `scheduleItems/${A}/items/n3`,
      alarm({
        tier: 'emergency',
        scheduledInstantUtc: new Date('2026-08-25T14:30:00Z'),
      })));
  });

  it('may claim a legacy slot lock', async () => {
    await assertSucceeds(setDoc(doc(as(B), `scheduleSlots/${A}/slots/999`), {
      targetUid: A, createdByUid: B, groupId: '', itemId: 'n1',
      createdAt: new Date(),
    }));
  });

  it('a leftover grant with granted:false does not take permission away', async () => {
    await seedRetired(`friendships/${PAIR}/plannerGrants/${GRANT}`, {
      plannerUid: B, targetUid: A, groupId: '', granted: false,
      grantedByUid: A, updatedAt: new Date(),
    });
    await assertSucceeds(getDoc(doc(as(B), itemPath)));
    await assertSucceeds(plan(as(B), `scheduleItems/${A}/items/n4`, alarm()));
  });

  it('an unknown tier or status is still denied', async () => {
    await assertFails(plan(as(B), `scheduleItems/${A}/items/x1`, alarm({ tier: 'urgent' })));
    await assertFails(plan(as(B), `scheduleItems/${A}/items/x2`, alarm({ status: 'withdrawn' })));
  });

  it('cannot create an item in someone else\'s name', async () => {
    await assertFails(plan(as(B), `scheduleItems/${A}/items/x3`, alarm({ createdByUid: A })));
  });
});

describe('ending the friendship ends the permission', () => {
  it('unfriending denies the read and the create at once', async () => {
    await assertSucceeds(getDoc(doc(as(B), itemPath)));
    await unfriend();
    await assertFails(getDoc(doc(as(B), itemPath)));
    await assertFails(plan(as(B), `scheduleItems/${A}/items/u1`, alarm()));
  });

  it('a leftover granted:true doc does not survive unfriending', async () => {
    await seedRetired(`friendships/${PAIR}/plannerGrants/${GRANT}`, {
      plannerUid: B, targetUid: A, groupId: '', granted: true,
      grantedByUid: A, updatedAt: new Date(),
    });
    await seedRetired(`friendships/${PAIR}/emergencyGrants/${GRANT}`, {
      plannerUid: B, targetUid: A, groupId: '', granted: true,
      grantedByUid: A, updatedAt: new Date(),
    });
    await unfriend();
    await assertFails(getDoc(doc(as(B), itemPath)));
    await assertFails(plan(as(B), `scheduleItems/${A}/items/u2`, alarm()));
  });
});

describe('a non-friend is denied', () => {
  it('cannot read or set an alarm', async () => {
    await assertFails(getDoc(doc(as(C), itemPath)));
    await assertFails(plan(as(C), `scheduleItems/${A}/items/c1`, alarm({ createdByUid: C })));
  });

  it('cannot claim a slot lock', async () => {
    await assertFails(setDoc(doc(as(C), `scheduleSlots/${A}/slots/998`), {
      targetUid: A, createdByUid: C, groupId: '', itemId: 'c1',
      createdAt: new Date(),
    }));
  });
});

describe('group labels on a friend\'s alarm', () => {
  it('a group both friends are in may label it', async () => {
    await assertSucceeds(plan(as(B), `scheduleItems/${A}/items/g1`, alarm({ groupId: GROUP })));
  });

  it('DENIES a group the target is not in, or that does not exist', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'groups', 'b_only'), {
        name: 'B only', ownerUid: B, joinCode: 'XYZ234', memberUids: [B],
      });
    });
    await assertFails(plan(as(B), `scheduleItems/${A}/items/g2`, alarm({ groupId: 'b_only' })));
    await assertFails(plan(as(B), `scheduleItems/${A}/items/g3`, alarm({ groupId: 'no_such_group' })));
  });
});

describe('a non-friend fellow member (item 3: group plans only)', () => {
  it('may set a GROUP-tagged alarm, with no grant', async () => {
    await assertSucceeds(plan(as(C), `scheduleItems/${A}/items/gc1`, alarm({ createdByUid: C, groupId: GROUP })));
  });

  it('may NOT set an untagged (personal) alarm, or read the schedule', async () => {
    await assertFails(plan(as(C), `scheduleItems/${A}/items/gc2`, alarm({ createdByUid: C })));
    await assertFails(getDoc(doc(as(C), itemPath)));
  });

  it('a leftover group grant + hint row changes nothing', async () => {
    await seedRetired(`groups/${GROUP}/plannerGrants/${C}_${A}`, {
      plannerUid: C, targetUid: A, groupId: GROUP, granted: true,
      grantedByUid: A, updatedAt: new Date(),
    });
    await seedRetired(`plannerAccess/${C}_${A}`, {
      plannerUid: C, targetUid: A, groupId: GROUP, updatedAt: new Date(),
    });
    await assertFails(getDoc(doc(as(C), itemPath)));
    await assertFails(plan(as(C), `scheduleItems/${A}/items/gc3`, alarm({ createdByUid: C })));
  });
});

describe('the retired documents', () => {
  const grant = {
    plannerUid: B, targetUid: A, groupId: '', granted: true, grantedByUid: A,
    updatedAt: new Date(),
  };

  it('no one can write a friendship grant or emergency grant any more', async () => {
    await assertFails(setDoc(
      doc(as(A), `friendships/${PAIR}/plannerGrants/${GRANT}`), grant));
    await assertFails(setDoc(
      doc(as(A), `friendships/${PAIR}/emergencyGrants/${GRANT}`), grant));
  });

  it('no one can send a planning-permission request any more', async () => {
    await assertFails(setDoc(doc(as(B), `planningRequests/${B}_${A}_normal`), {
      fromUid: B, toUid: A, kind: 'normal', participants: [B, A],
      status: 'pending', createdAt: new Date(), updatedAt: new Date(),
    }));
  });

  it('the parties may read and delete leftovers; an outsider may not', async () => {
    const g = `friendships/${PAIR}/plannerGrants/${GRANT}`;
    const e = `friendships/${PAIR}/emergencyGrants/${GRANT}`;
    const r = `planningRequests/${B}_${A}_normal`;
    await seedRetired(g, grant);
    await seedRetired(e, grant);
    await seedRetired(r, {
      fromUid: B, toUid: A, kind: 'normal', participants: [B, A],
      status: 'pending', createdAt: new Date(), updatedAt: new Date(),
    });
    await assertFails(getDoc(doc(as(C), g)));
    await assertFails(deleteDoc(doc(as(C), r)));
    await assertSucceeds(getDoc(doc(as(B), g)));
    await assertSucceeds(deleteDoc(doc(as(A), g)));
    await assertSucceeds(deleteDoc(doc(as(B), e)));
    await assertSucceeds(deleteDoc(doc(as(A), r)));
  });
});

describe('cancel still belongs to the creator', () => {
  it('the creator may cancel an unanswered alarm; nobody else may', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `scheduleItems/${A}/items/k1`), alarm());
    });
    const cancel = { status: 'withdrawn', withdrawnAt: new Date(), updatedAt: new Date() };
    await assertFails(setDoc(doc(as(C), `scheduleItems/${A}/items/k1`), cancel, { merge: true }));
    await assertSucceeds(setDoc(doc(as(B), `scheduleItems/${A}/items/k1`), cancel, { merge: true }));
  });

  it('the creator may NOT cancel an alarm that was already answered', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `scheduleItems/${A}/items/k2`),
        alarm({ outcome: { result: 'done' } }));
    });
    await assertFails(setDoc(doc(as(B), `scheduleItems/${A}/items/k2`),
      { status: 'withdrawn', withdrawnAt: new Date(), updatedAt: new Date() },
      { merge: true }));
  });
});
