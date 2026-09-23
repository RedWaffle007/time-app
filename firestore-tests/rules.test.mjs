// Security-rules unit tests for ../firestore.rules.
//
// These cover the two findings in ARCHITECTURE.md §4.1 that the rules were
// changed to close:
//
//   ISSUE 1 — collection enumeration. `allow read: if signedIn()` on `users`
//             and `groups` authorised LIST, so any signed-in account could dump
//             every profile (name / timezone / quiet hours) and every group
//             (name / roster / invite code).
//   ISSUE 2 — notification suppression. The item update rule was
//             document-level, so a target could pre-write the push Worker's
//             `notified*` dedup fields and silence the planner's notification.
//
// Every denial case is paired with the legitimate write it must NOT break —
// a rule that denies everything would pass the first half of this file.
//
// Run: npm test   (starts the Firestore emulator via firebase-tools)

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  addDoc,
  collection,
  collectionGroup,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  serverTimestamp,
  setDoc,
  Timestamp,
  where,
  writeBatch,
} from 'firebase/firestore';

// --- fixtures -------------------------------------------------------------

const ALICE = 'uid_alice'; // the TARGET — items live under her subtree
const BOB = 'uid_bob'; // the PLANNER — holds an active grant over Alice
const MALLORY = 'uid_mallory'; // signed in, in no group with anyone

const GROUP = 'group_1';
const JOIN_CODE = 'HJK234';
const PENDING_ITEM = 'item_pending';
const APPROVED_ITEM = 'item_approved';

let testEnv;

/** The exact field set ScheduleRepository.createItem writes. */
function newItemFields(overrides = {}) {
  return {
    targetUid: ALICE,
    createdByUid: BOB,
    groupId: GROUP,
    title: 'Morning run',
    note: 'bring water',
    localWallTime: '2026-08-11 07:00',
    timezone: 'Asia/Kolkata',
    scheduledInstantUtc: Timestamp.fromDate(new Date('2026-08-11T01:30:00Z')),
    status: 'pending',
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

/** Reset to a known world: one group, one grant, two items, three profiles. */
async function seed() {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();

    for (const uid of [ALICE, BOB, MALLORY]) {
      await setDoc(doc(db, 'users', uid), {
        name: uid,
        homeTimezone: 'Asia/Kolkata',
        quietHoursStartMinutes: 1380,
        quietHoursEndMinutes: 360,
      });
    }

    await setDoc(doc(db, 'groups', GROUP), {
      name: 'The group',
      ownerUid: ALICE,
      joinCode: JOIN_CODE,
      memberUids: [ALICE, BOB],
    });
    await setDoc(doc(db, 'groups', GROUP, 'members', ALICE), { name: 'Alice' });
    await setDoc(doc(db, 'groups', GROUP, 'members', BOB), { name: 'Bob' });
    await setDoc(doc(db, 'groups', GROUP, 'plannerGrants', `${BOB}_${ALICE}`), {
      plannerUid: BOB,
      targetUid: ALICE,
      groupId: GROUP,
      granted: true,
      grantedByUid: ALICE,
    });
    await setDoc(doc(db, 'joinCodes', JOIN_CODE), { groupId: GROUP });

    const items = collection(db, 'scheduleItems', ALICE, 'items');
    await setDoc(doc(items, PENDING_ITEM), {
      targetUid: ALICE,
      createdByUid: BOB,
      groupId: GROUP,
      title: 'Morning run',
      localWallTime: '2026-08-11 07:00',
      timezone: 'Asia/Kolkata',
      scheduledInstantUtc: Timestamp.fromDate(new Date('2026-08-11T01:30:00Z')),
      status: 'pending',
    });
    await setDoc(doc(items, APPROVED_ITEM), {
      targetUid: ALICE,
      createdByUid: BOB,
      groupId: GROUP,
      title: 'Evening study',
      localWallTime: '2026-08-11 19:00',
      timezone: 'Asia/Kolkata',
      scheduledInstantUtc: Timestamp.fromDate(new Date('2026-08-11T13:30:00Z')),
      status: 'approved',
    });
  });
}

const as = (uid) => testEnv.authenticatedContext(uid).firestore();
const itemRef = (db, id) => doc(db, 'scheduleItems', ALICE, 'items', id);

function codeJoinRequest() {
  return {
    candidateUid: MALLORY,
    candidateName: MALLORY,
    requestedByUid: MALLORY,
    source: 'code',
    inviteCode: JOIN_CODE,
    status: 'pending',
    requiredApproverUids: [],
    approvalUids: [],
    rejectionUid: null,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };
}

async function submitCodeJoinRequest() {
  const ref = doc(as(MALLORY), 'groups', GROUP, 'joinRequests', MALLORY);
  await assertSucceeds(setDoc(ref, codeJoinRequest()));
  return ref;
}

before(async () => {
  const host = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
  const [emulatorHost, emulatorPort] = host.split(':');
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-time-app',
    firestore: {
      rules: readFileSync('../firestore.rules', 'utf8'),
      host: emulatorHost,
      port: Number(emulatorPort),
    },
  });
});

after(async () => {
  await testEnv?.cleanup();
});

beforeEach(seed);

// --- ISSUE 1: enumeration -------------------------------------------------

describe('issue 1 — users are not enumerable', () => {
  it('DENIES a non-member listing the users collection', async () => {
    // The finding itself: this used to return every profile in the project.
    await assertFails(getDocs(collection(as(MALLORY), 'users')));
  });

  it('DENIES listing users even to a legitimate member', async () => {
    // `list` is off for everyone — no client path queries this collection.
    await assertFails(getDocs(collection(as(BOB), 'users')));
  });

  it('DENIES a filtered query that tries to sweep quiet-hours windows', async () => {
    await assertFails(
      getDocs(
        query(
          collection(as(MALLORY), 'users'),
          where('homeTimezone', '==', 'Asia/Kolkata'),
        ),
      ),
    );
  });

  it('ALLOWS reading one profile by uid (the planner needs name + timezone)', async () => {
    await assertSucceeds(getDoc(doc(as(BOB), 'users', ALICE)));
  });

  it('documents the ACCEPTED RESIDUAL: a known uid can still be read', async () => {
    // Not a bug being asserted as correct — a limit being pinned down. Strict
    // shared-group scoping needs a denormalized index (see the rules comment).
    // It holds only because no uid leaks to a stranger any more.
    await assertSucceeds(getDoc(doc(as(MALLORY), 'users', ALICE)));
  });
});

// --- six-hour inactivity state -------------------------------------------

describe('inactivity state is private and client fields are constrained', () => {
  const activityAt = Timestamp.fromDate(new Date('2026-09-23T06:00:00Z'));
  const dueAt = Timestamp.fromDate(new Date('2026-09-23T12:00:00Z'));
  const stateRef = (db, uid = ALICE) => doc(db, 'inactivityStates', uid);

  it('allows the owner to create the exact six-hour timer', async () => {
    await assertSucceeds(setDoc(stateRef(as(ALICE)), {
      uid: ALICE,
      lastActivityAt: activityAt,
      nextNotificationAt: dueAt,
    }));
  });

  it('denies another user and all collection enumeration', async () => {
    await assertFails(setDoc(stateRef(as(BOB)), {
      uid: ALICE,
      lastActivityAt: activityAt,
      nextNotificationAt: dueAt,
    }));
    await assertFails(getDoc(stateRef(as(BOB))));
    await assertFails(getDocs(collection(as(ALICE), 'inactivityStates')));
  });

  it('denies forged due times and Worker-owned delivery fields', async () => {
    await assertFails(setDoc(stateRef(as(ALICE)), {
      uid: ALICE,
      lastActivityAt: activityAt,
      nextNotificationAt: Timestamp.fromDate(new Date('2027-01-01T00:00:00Z')),
    }));
    await assertFails(setDoc(stateRef(as(ALICE)), {
      uid: ALICE,
      lastActivityAt: activityAt,
      nextNotificationAt: dueAt,
      sequenceIndex: 49,
    }));
  });

  it('preserves Worker fields while allowing a later owner activity update', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(stateRef(ctx.firestore()), {
        uid: ALICE,
        lastActivityAt: activityAt,
        nextNotificationAt: dueAt,
        sequenceIndex: 7,
        lastNotifiedAt: Timestamp.fromDate(new Date('2026-09-22T12:00:00Z')),
      });
    });
    await assertSucceeds(setDoc(stateRef(as(ALICE)), {
      lastActivityAt: Timestamp.fromDate(new Date('2026-09-23T07:00:00Z')),
      nextNotificationAt: Timestamp.fromDate(new Date('2026-09-23T13:00:00Z')),
    }, { merge: true }));
    await assertFails(setDoc(stateRef(as(ALICE)), {
      sequenceIndex: 0,
    }, { merge: true }));
  });
});

// --- the profile name is required, server-side ----------------------------
//
// It used to be enforced only by two widget getters. These cases pin the rule
// to the client's own check (`name.trim().isNotEmpty`) and, more importantly,
// prove the repair path: the constraint is evaluated on the POST-WRITE
// document, so it can never block the write that fixes an empty name.

describe('the profile name is required', () => {
  const NEWBIE = 'uid_newbie'; // no user doc — writes here are CREATEs

  /** Give a uid an empty stored name, bypassing rules. */
  async function withStoredName(uid, name) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'users', uid), {
        name,
        homeTimezone: 'Asia/Kolkata',
      });
    });
  }

  it('ALLOWS create with a real name', async () => {
    await assertSucceeds(
      setDoc(doc(as(NEWBIE), 'users', NEWBIE), {
        name: 'Newbie',
        homeTimezone: 'Asia/Kolkata',
      }),
    );
  });

  it('DENIES create with an empty name', async () => {
    await assertFails(
      setDoc(doc(as(NEWBIE), 'users', NEWBIE), {
        name: '',
        homeTimezone: 'Asia/Kolkata',
      }),
    );
  });

  it('DENIES create with a whitespace-only name', async () => {
    await assertFails(
      setDoc(doc(as(NEWBIE), 'users', NEWBIE), {
        name: '   ',
        homeTimezone: 'Asia/Kolkata',
      }),
    );
  });

  it('DENIES create with no name field at all', async () => {
    await assertFails(
      setDoc(doc(as(NEWBIE), 'users', NEWBIE), {
        homeTimezone: 'Asia/Kolkata',
      }),
    );
  });

  it('ALLOWS update to a new name', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'users', ALICE), { name: 'Alice A.' }, { merge: true }),
    );
  });

  it('ALLOWS update FROM an empty name to a real one — the repair path', async () => {
    // The case the whole design turns on. `request.resource.data` is the
    // post-write document, so the corrective write satisfies the rule by
    // construction and nobody is locked out of their own profile.
    await withStoredName(ALICE, '');
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'users', ALICE), { name: 'Alice' }, { merge: true }),
    );
  });

  it('DENIES an update that blanks an existing name', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE), { name: '' }, { merge: true }),
    );
  });

  it('ALLOWS a merge update that does not touch the name', async () => {
    // The legitimate operation the rule must not break: a partial write
    // inherits the stored name, which is already valid.
    await assertSucceeds(
      setDoc(
        doc(as(ALICE), 'users', ALICE),
        { quietHoursStartMinutes: 1320 },
        { merge: true },
      ),
    );
  });

  it('documents the CONSEQUENCE: a partial write is denied while the stored name is empty', async () => {
    // Not a bug asserted as correct — the known edge of checking the post-write
    // document, pinned so it cannot surprise anyone later. A write that does not
    // carry `name` inherits the empty stored one and is denied by a field it
    // never touched. Retired in practice by verifying no such document exists
    // (2026-08-15); this is what would happen if one did.
    await withStoredName(ALICE, '');
    await assertFails(
      setDoc(
        doc(as(ALICE), 'users', ALICE),
        { quietHoursStartMinutes: 1320 },
        { merge: true },
      ),
    );
  });
});

describe('issue 1 — groups are not enumerable', () => {
  it('DENIES a non-member reading a group document', async () => {
    await assertFails(getDoc(doc(as(MALLORY), 'groups', GROUP)));
  });

  it('DENIES a non-member listing every group', async () => {
    await assertFails(getDocs(collection(as(MALLORY), 'groups')));
  });

  it('DENIES the join-by-code query, which is how invite codes leaked', async () => {
    // The client resolves one exact joinCodes/{code} document instead.
    await assertFails(
      getDocs(
        query(
          collection(as(MALLORY), 'groups'),
          where('joinCode', '==', JOIN_CODE),
        ),
      ),
    );
  });

  it('DENIES a non-member reading the member roster', async () => {
    await assertFails(
      getDocs(collection(as(MALLORY), 'groups', GROUP, 'members')),
    );
  });

  it('ALLOWS a member to read their own group', async () => {
    await assertSucceeds(getDoc(doc(as(BOB), 'groups', GROUP)));
  });

  it('ALLOWS watchMyGroups (array-contains on memberUids)', async () => {
    await assertSucceeds(
      getDocs(
        query(
          collection(as(BOB), 'groups'),
          where('memberUids', 'array-contains', BOB),
        ),
      ),
    );
  });

  it('ALLOWS creating a group as its owner and sole member', async () => {
    await assertSucceeds(
      setDoc(doc(as(MALLORY), 'groups', 'group_new'), {
        name: 'Mallory only',
        ownerUid: MALLORY,
        joinCode: 'ZZZ999',
        memberUids: [MALLORY],
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES the former direct self-join path', async () => {
    await assertFails(
      setDoc(
        doc(as(MALLORY), 'groups', GROUP),
        { memberUids: [ALICE, BOB, MALLORY] },
        { merge: true },
      ),
    );
  });
});

describe('unanimous group admission', () => {
  it('ALLOWS resolving a code you were given', async () => {
    await assertSucceeds(getDoc(doc(as(MALLORY), 'joinCodes', JOIN_CODE)));
  });

  it('DENIES listing codes, so they cannot be swept in bulk', async () => {
    await assertFails(getDocs(collection(as(MALLORY), 'joinCodes')));
  });

  it('ALLOWS the group owner to register their code', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'joinCodes', 'NEWCODE'), { groupId: GROUP }),
    );
  });

  it('DENIES a non-owner registering a code for that group', async () => {
    await assertFails(
      setDoc(doc(as(BOB), 'joinCodes', 'NEWCODE'), { groupId: GROUP }),
    );
  });

  it('DENIES repointing an existing code at another group', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'joinCodes', JOIN_CODE), { groupId: 'group_other' }),
    );
  });

  it('turns a valid code into a pending request, not membership', async () => {
    await submitCodeJoinRequest();
    await assertFails(getDoc(doc(as(MALLORY), 'groups', GROUP)));
    await assertSucceeds(
      getDoc(doc(as(MALLORY), 'groups', GROUP, 'joinRequests', MALLORY)),
    );
  });

  it('DENIES a code request aimed at a different group', async () => {
    await assertFails(
      setDoc(
        doc(as(MALLORY), 'groups', 'forged_group', 'joinRequests', MALLORY),
        codeJoinRequest(),
      ),
    );
  });

  it('lets a member nominate their friend but not admit them directly', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'friendships', `${ALICE}_${MALLORY}`), {
        uidA: ALICE,
        uidB: MALLORY,
        participants: [ALICE, MALLORY],
      });
    });
    const db = as(ALICE);
    await assertSucceeds(
      setDoc(doc(db, 'groups', GROUP, 'joinRequests', MALLORY), {
        candidateUid: MALLORY,
        candidateName: MALLORY,
        requestedByUid: ALICE,
        source: 'friend',
        inviteCode: null,
        status: 'pending',
        requiredApproverUids: [ALICE, BOB],
        approvalUids: [ALICE],
        rejectionUid: null,
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(
        doc(db, 'groups', GROUP),
        {
          memberUids: [ALICE, BOB, MALLORY],
          lastAdmittedUid: MALLORY,
        },
        { merge: true },
      ),
    );
  });

  it('DENIES adding the candidate after only one of two approvals', async () => {
    await submitCodeJoinRequest();
    const db = as(ALICE);
    const batch = writeBatch(db);
    batch.update(doc(db, 'groups', GROUP, 'joinRequests', MALLORY), {
      requiredApproverUids: [ALICE, BOB],
      approvalUids: [ALICE],
      status: 'pending',
      updatedAt: serverTimestamp(),
    });
    batch.update(doc(db, 'groups', GROUP), {
      memberUids: [ALICE, BOB, MALLORY],
      lastAdmittedUid: MALLORY,
    });
    batch.set(doc(db, 'groups', GROUP, 'members', MALLORY), {
      name: MALLORY,
      joinedAt: serverTimestamp(),
    });
    await assertFails(batch.commit());
  });

  it('DENIES forging another member approval', async () => {
    await submitCodeJoinRequest();
    await assertFails(
      setDoc(
        doc(as(ALICE), 'groups', GROUP, 'joinRequests', MALLORY),
        {
          requiredApproverUids: [ALICE, BOB],
          approvalUids: [ALICE, BOB],
          status: 'approved',
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
  });

  it('admits atomically after every current member approves', async () => {
    await submitCodeJoinRequest();
    await assertSucceeds(
      setDoc(
        doc(as(ALICE), 'groups', GROUP, 'joinRequests', MALLORY),
        {
          requiredApproverUids: [ALICE, BOB],
          approvalUids: [ALICE],
          status: 'pending',
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );

    const db = as(BOB);
    const batch = writeBatch(db);
    batch.update(doc(db, 'groups', GROUP, 'joinRequests', MALLORY), {
      requiredApproverUids: [ALICE, BOB],
      approvalUids: [ALICE, BOB],
      status: 'approved',
      updatedAt: serverTimestamp(),
    });
    batch.update(doc(db, 'groups', GROUP), {
      memberUids: [ALICE, BOB, MALLORY],
      lastAdmittedUid: MALLORY,
    });
    batch.set(doc(db, 'groups', GROUP, 'members', MALLORY), {
      name: MALLORY,
      joinedAt: serverTimestamp(),
    });
    await assertSucceeds(batch.commit());
    await assertSucceeds(getDoc(doc(as(MALLORY), 'groups', GROUP)));
  });

  it('makes one member rejection terminal', async () => {
    await submitCodeJoinRequest();
    const request = doc(as(ALICE), 'groups', GROUP, 'joinRequests', MALLORY);
    await assertSucceeds(
      setDoc(
        request,
        {
          status: 'rejected',
          rejectionUid: ALICE,
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
    await assertFails(
      setDoc(
        doc(as(BOB), 'groups', GROUP, 'joinRequests', MALLORY),
        {
          requiredApproverUids: [ALICE, BOB],
          approvalUids: [ALICE, BOB],
          status: 'approved',
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
  });
});

describe('durable completion celebrations', () => {
  const celebrationId = `${ALICE}_${APPROVED_ITEM}`;
  const celebrationPath = `completionCelebrations/${celebrationId}`;
  const celebration = () => ({
    itemId: APPROVED_ITEM,
    targetUid: ALICE,
    plannerUid: BOB,
    participantUids: [ALICE, BOB],
    seenByUids: [],
    createdAt: serverTimestamp(),
  });

  it('DENIES creating an event without the matching done transition', async () => {
    await assertFails(setDoc(doc(as(ALICE), celebrationPath), celebration()));
  });

  it('creates the done outcome and event atomically for both participants', async () => {
    const db = as(ALICE);
    const batch = writeBatch(db);
    batch.set(itemRef(db, APPROVED_ITEM), {
      outcome: { result: 'done', completedAt: serverTimestamp() },
      updatedAt: serverTimestamp(),
    }, { merge: true });
    batch.set(doc(db, celebrationPath), celebration());
    await assertSucceeds(batch.commit());

    await assertSucceeds(getDoc(doc(as(BOB), celebrationPath)));
    await assertFails(getDoc(doc(as(MALLORY), celebrationPath)));
  });

  it('allows each participant to acknowledge only themselves', async () => {
    const db = as(ALICE);
    const batch = writeBatch(db);
    batch.set(itemRef(db, APPROVED_ITEM), {
      outcome: { result: 'done', completedAt: serverTimestamp() },
      updatedAt: serverTimestamp(),
    }, { merge: true });
    batch.set(doc(db, celebrationPath), celebration());
    await assertSucceeds(batch.commit());

    await assertSucceeds(setDoc(doc(as(ALICE), celebrationPath), {
      seenByUids: [ALICE],
    }, { merge: true }));
    await assertFails(setDoc(doc(as(BOB), celebrationPath), {
      seenByUids: [ALICE, MALLORY],
    }, { merge: true }));
    await assertSucceeds(deleteDoc(doc(as(BOB), celebrationPath)));
    await assertFails(setDoc(doc(as(ALICE), celebrationPath), celebration()));
  });

  it('DENIES an outsider enumerating celebration events', async () => {
    await assertFails(getDocs(collection(as(MALLORY), 'completionCelebrations')));
  });
});

// --- ISSUE 2: notification suppression ------------------------------------

describe('issue 2 — no client may write the Worker dedup fields', () => {
  it('DENIES the target pre-writing notifiedOutcome to suppress the push', async () => {
    // The finding itself: with this field set, notify.js answers
    // `already-notified` and the planner never hears that the item was done.
    await assertFails(
      setDoc(
        itemRef(as(ALICE), APPROVED_ITEM),
        {
          outcome: { result: 'done', completedAt: serverTimestamp() },
          notifiedOutcome: 'done',
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
  });

  it('DENIES the target writing notifiedOutcome on its own', async () => {
    await assertFails(
      setDoc(
        itemRef(as(ALICE), APPROVED_ITEM),
        { notifiedOutcome: 'done' },
        { merge: true },
      ),
    );
  });

  it('DENIES the target writing notifiedDecided', async () => {
    await assertFails(
      setDoc(
        itemRef(as(ALICE), PENDING_ITEM),
        {
          status: 'approved',
          decidedAt: serverTimestamp(),
          notifiedDecided: 'approved',
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
  });

  it('DENIES the target writing notifiedCreated or notifiedAt', async () => {
    await assertFails(
      setDoc(
        itemRef(as(ALICE), PENDING_ITEM),
        { notifiedCreated: true, notifiedAt: 'now', updatedAt: serverTimestamp() },
        { merge: true },
      ),
    );
  });

  it('DENIES the planner pre-stamping notifiedCreated at CREATE time', async () => {
    // The same hole through the other door: an item born pre-silenced would
    // never fire its `created` push.
    await assertFails(
      addDoc(
        collection(as(BOB), 'scheduleItems', ALICE, 'items'),
        newItemFields({ notifiedCreated: true }),
      ),
    );
  });

  it('DENIES the planner writing notifiedWithdrawn while withdrawing', async () => {
    await assertFails(
      setDoc(
        itemRef(as(BOB), PENDING_ITEM),
        {
          status: 'withdrawn',
          withdrawnAt: serverTimestamp(),
          notifiedWithdrawn: true,
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
  });
});

describe('alarm timeline writes', () => {
  it('allows the target to record reached alarm events', async () => {
    await assertSucceeds(setDoc(itemRef(as(ALICE), APPROVED_ITEM), {
      alarm: {
        rangAt: Timestamp.fromDate(new Date('2026-08-11T13:30:01Z')),
        dismissedAt: Timestamp.fromDate(new Date('2026-08-11T13:30:10Z')),
      },
      updatedAt: serverTimestamp(),
    }, { merge: true }));
  });

  it('denies planners, outsiders, and unknown alarm fields', async () => {
    const alarm = {
      rangAt: Timestamp.fromDate(new Date('2026-08-11T13:30:01Z')),
    };
    await assertFails(setDoc(itemRef(as(BOB), APPROVED_ITEM), {
      alarm, updatedAt: serverTimestamp(),
    }, { merge: true }));
    await assertFails(setDoc(itemRef(as(MALLORY), APPROVED_ITEM), {
      alarm, updatedAt: serverTimestamp(),
    }, { merge: true }));
    await assertFails(setDoc(itemRef(as(ALICE), APPROVED_ITEM), {
      alarm: { ...alarm, forged: true },
      updatedAt: serverTimestamp(),
    }, { merge: true }));
  });

  it('denies alarm events on an unapproved item', async () => {
    await assertFails(setDoc(itemRef(as(ALICE), PENDING_ITEM), {
      alarm: {
        rangAt: Timestamp.fromDate(new Date('2026-08-11T13:30:01Z')),
      },
      updatedAt: serverTimestamp(),
    }, { merge: true }));
  });
});

describe('issue 2 — the target cannot rewrite the plan itself', () => {
  it('DENIES the target editing the title', async () => {
    await assertFails(
      setDoc(
        itemRef(as(ALICE), PENDING_ITEM),
        { title: 'something else', updatedAt: serverTimestamp() },
        { merge: true },
      ),
    );
  });

  it('DENIES the target moving scheduledInstantUtc', async () => {
    await assertFails(
      setDoc(
        itemRef(as(ALICE), PENDING_ITEM),
        {
          scheduledInstantUtc: Timestamp.fromDate(new Date('2027-01-01T00:00:00Z')),
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
  });

  it('DENIES the target reassigning createdByUid', async () => {
    await assertFails(
      setDoc(
        itemRef(as(ALICE), PENDING_ITEM),
        { createdByUid: ALICE, updatedAt: serverTimestamp() },
        { merge: true },
      ),
    );
  });

  it('DENIES the target reviving an approved item back to pending', async () => {
    await assertFails(
      setDoc(
        itemRef(as(ALICE), APPROVED_ITEM),
        { status: 'pending', updatedAt: serverTimestamp() },
        { merge: true },
      ),
    );
  });

  it('DENIES the target faking a planner withdrawal', async () => {
    await assertFails(
      setDoc(
        itemRef(as(ALICE), PENDING_ITEM),
        { status: 'withdrawn', updatedAt: serverTimestamp() },
        { merge: true },
      ),
    );
  });
});

describe('issue 2 — every legitimate write still works', () => {
  it('ALLOWS the planner to create a pending item under an active grant', async () => {
    await assertSucceeds(
      addDoc(
        collection(as(BOB), 'scheduleItems', ALICE, 'items'),
        newItemFields(),
      ),
    );
  });

  it('ALLOWS a self-planned approved item', async () => {
    await assertSucceeds(
      addDoc(
        collection(as(ALICE), 'scheduleItems', ALICE, 'items'),
        newItemFields({
          createdByUid: ALICE,
          groupId: '',
          status: 'approved',
          decidedAt: serverTimestamp(),
        }),
      ),
    );
  });

  it('ALLOWS the target to approve', async () => {
    await assertSucceeds(
      setDoc(
        itemRef(as(ALICE), PENDING_ITEM),
        { status: 'approved', decidedAt: serverTimestamp(), updatedAt: serverTimestamp() },
        { merge: true },
      ),
    );
  });

  it('ALLOWS the target to reject with a reason', async () => {
    await assertSucceeds(
      setDoc(
        itemRef(as(ALICE), PENDING_ITEM),
        {
          status: 'rejected',
          decidedAt: serverTimestamp(),
          rejectionReason: 'clashes with work',
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
  });

  it('ALLOWS the target to mark done', async () => {
    await assertSucceeds(
      setDoc(
        itemRef(as(ALICE), APPROVED_ITEM),
        {
          outcome: { result: 'done', completedAt: serverTimestamp() },
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
  });

  it('ALLOWS the target to mark skipped with a reason', async () => {
    await assertSucceeds(
      setDoc(
        itemRef(as(ALICE), APPROVED_ITEM),
        {
          outcome: {
            result: 'skipped',
            skippedAt: serverTimestamp(),
            skipReason: 'was ill',
          },
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
  });

  it('DENIES replacing a settled outcome', async () => {
    const ref = itemRef(as(ALICE), APPROVED_ITEM);
    await assertSucceeds(setDoc(ref, {
      outcome: {
        result: 'skipped',
        skippedAt: serverTimestamp(),
        skipReason: 'Not today',
      },
      updatedAt: serverTimestamp(),
    }, { merge: true }));

    await assertFails(setDoc(ref, {
      outcome: { result: 'done', completedAt: serverTimestamp() },
      updatedAt: serverTimestamp(),
    }, { merge: true }));
    await assertFails(setDoc(ref, {
      outcome: {
        result: 'skipped',
        skippedAt: serverTimestamp(),
        skipReason: 'Changed my mind',
      },
      updatedAt: serverTimestamp(),
    }, { merge: true }));
  });

  it('ALLOWS only the automatic lapse reason to refine to alarm timeout', async () => {
    const ref = itemRef(as(ALICE), APPROVED_ITEM);
    await assertSucceeds(setDoc(ref, {
      outcome: {
        result: 'skipped',
        skippedAt: serverTimestamp(),
        skipReason: 'Did not respond',
      },
      updatedAt: serverTimestamp(),
    }, { merge: true }));

    await assertSucceeds(setDoc(ref, {
      outcome: {
        result: 'skipped',
        skippedAt: serverTimestamp(),
        skipReason: 'User unavailable',
      },
      updatedAt: serverTimestamp(),
    }, { merge: true }));
  });

  it('ALLOWS the planner to withdraw a still-pending item', async () => {
    await assertSucceeds(
      setDoc(
        itemRef(as(BOB), PENDING_ITEM),
        {
          status: 'withdrawn',
          withdrawnAt: serverTimestamp(),
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      ),
    );
  });

  it('ALLOWS the planner their cross-target collection-group read', async () => {
    // watchItemsByPlanner — matched only by the /{path=**}/items rule.
    await assertSucceeds(
      getDocs(
        query(
          collectionGroup(as(BOB), 'items'),
          where('createdByUid', '==', BOB),
        ),
      ),
    );
  });

  it('DENIES an outsider the same collection-group read', async () => {
    await assertFails(getDocs(collectionGroup(as(MALLORY), 'items')));
  });
});


// --- Group memberStats (accountability + leaderboard, 2026-08-26) ----------
// Each member publishes their OWN summary; any member reads; no one forges
// another's. Same published-not-derived doctrine as profileStats.
describe('group memberStats — publish own, read as a member', () => {
  const statPath = (uid) => `groups/${GROUP}/memberStats/${uid}`;
  const stats = (o = {}) => ({
    name: 'Alice', tasksCompleted: 5, currentStreak: 3, followThrough: 80,
    updatedAt: serverTimestamp(), ...o,
  });

  it('a member publishes their OWN stats', async () => {
    await assertSucceeds(setDoc(doc(as(ALICE), statPath(ALICE)), stats()));
  });

  it('a member cannot forge ANOTHER member\'s stats', async () => {
    await assertFails(setDoc(doc(as(BOB), statPath(ALICE)), stats()));
  });

  it('a non-member cannot publish', async () => {
    await assertFails(setDoc(doc(as(MALLORY), statPath(MALLORY)), stats()));
  });

  it('a member reads a fellow member\'s stats', async () => {
    await setDoc(doc(as(ALICE), statPath(ALICE)), stats());
    await assertSucceeds(getDoc(doc(as(BOB), statPath(ALICE))));
  });

  it('a non-member cannot read', async () => {
    await setDoc(doc(as(ALICE), statPath(ALICE)), stats());
    await assertFails(getDoc(doc(as(MALLORY), statPath(ALICE))));
  });

  it('an unknown field is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), statPath(ALICE)), stats({ secretRank: 1 })));
  });

  it('a member may delete their own stats', async () => {
    await setDoc(doc(as(ALICE), statPath(ALICE)), stats());
    await assertSucceeds(deleteDoc(doc(as(ALICE), statPath(ALICE))));
  });
});
