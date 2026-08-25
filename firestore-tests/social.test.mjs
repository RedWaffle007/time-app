// Security-rules unit tests for the SOCIAL layer of ../firestore.rules.
//
// Separate file from rules.test.mjs deliberately: that one covers the
// delegation loop and the two ARCHITECTURE.md §4.1 findings, and it has its own
// fixed world (one group, one grant, two items). The social graph needs a
// different world, and interleaving the two seeds would make both harder to
// read.
//
// What is worth testing here is the part the CLIENT cannot enforce:
//
//   * the privacy toggle actually gates stats;
//   * a block outranks both friendship and a public profile;
//   * a friendship cannot be conjured without a real pending request;
//   * a username cannot be displayed without holding the reservation;
//   * neither users nor usernames can be enumerated.
//
// Every denial is paired with the legitimate operation it must NOT break — a
// rule that denied everything would pass half of this file.
//
// Run: npm test  (starts the emulator; picks up *.test.mjs)

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
  query,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
} from 'firebase/firestore';

// Chosen so ANNA < BEN < CARA lexicographically, which makes the sorted
// friendship ids readable below rather than something to work out each time.
const ANNA = 'uid_anna';
const BEN = 'uid_ben';
const CARA = 'uid_cara';

const pair = (a, b) => (a < b ? `${a}_${b}` : `${b}_${a}`);

let testEnv;

/**
 * A world with:
 *   - three profiles: Anna PRIVATE, Ben PRIVATE, Cara PUBLIC
 *   - Anna and Ben are friends
 *   - Cara has a pending request TO Anna
 *   - usernames claimed for all three
 *   - published stats for all three
 */
async function seed() {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();

    const profiles = [
      [ANNA, 'anna', false],
      [BEN, 'ben', false],
      [CARA, 'cara', true],
    ];
    for (const [uid, handle, isPublic] of profiles) {
      await setDoc(doc(db, 'users', uid), {
        name: uid,
        homeTimezone: 'Asia/Kolkata',
        username: handle,
        isPublic,
      });
      await setDoc(doc(db, 'usernames', handle), { uid });
      await setDoc(doc(db, 'users', uid, 'profileStats', 'summary'), {
        values: { tasksCompleted: 7 },
        version: 1,
      });
    }

    await setDoc(doc(db, 'friendships', pair(ANNA, BEN)), {
      uidA: ANNA < BEN ? ANNA : BEN,
      uidB: ANNA < BEN ? BEN : ANNA,
      participants: [ANNA, BEN],
    });

    await setDoc(doc(db, 'friendRequests', `${CARA}_${ANNA}`), {
      fromUid: CARA,
      toUid: ANNA,
      participants: [CARA, ANNA],
      status: 'pending',
    });
  });
}

const as = (uid) => testEnv.authenticatedContext(uid).firestore();
const statsRef = (db, uid) => doc(db, 'users', uid, 'profileStats', 'summary');

/** Place a block, bypassing rules — the setup for "a block outranks X". */
async function placeBlock(blocker, blocked) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'blocks', `${blocker}_${blocked}`), {
      blockerUid: blocker,
      blockedUid: blocked,
    });
  });
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

// --- the privacy toggle ---------------------------------------------------

describe('profileStats — the privacy toggle is the ONLY thing with teeth', () => {
  it('ALLOWS the owner to read their own stats', async () => {
    await assertSucceeds(getDoc(statsRef(as(ANNA), ANNA)));
  });

  it('ALLOWS a FRIEND to read a private profile’s stats', async () => {
    await assertSucceeds(getDoc(statsRef(as(BEN), ANNA)));
  });

  it('DENIES a stranger reading a PRIVATE profile’s stats', async () => {
    // The whole feature. Cara has a pending request to Anna and is still
    // refused — a request must not be a way to peek.
    await assertFails(getDoc(statsRef(as(CARA), ANNA)));
  });

  it('ALLOWS a stranger reading a PUBLIC profile’s stats (the leaderboard)', async () => {
    await assertSucceeds(getDoc(statsRef(as(BEN), CARA)));
  });

  it('DENIES writing someone else’s stats', async () => {
    // On a leaderboard this is the entire game.
    await assertFails(
      setDoc(statsRef(as(BEN), ANNA), { values: { tasksCompleted: 9999 } }),
    );
  });

  it('ALLOWS publishing your own', async () => {
    await assertSucceeds(
      setDoc(statsRef(as(ANNA), ANNA), {
        values: { tasksCompleted: 8 },
        version: 1,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES listing the profileStats collection', async () => {
    await assertFails(
      getDocs(collection(as(ANNA), 'users', ANNA, 'profileStats')),
    );
  });
});

// --- blocking -------------------------------------------------------------

describe('blocks outrank everything', () => {
  it('DENIES a blocked FRIEND reading stats', async () => {
    // A stale friendship row can genuinely coexist with a fresh block, because
    // the cleanup spans several documents and is not atomic. The block wins.
    await placeBlock(ANNA, BEN);
    await assertFails(getDoc(statsRef(as(BEN), ANNA)));
  });

  it('DENIES stats to someone the owner blocked, even PUBLIC', async () => {
    await placeBlock(CARA, BEN);
    await assertFails(getDoc(statsRef(as(BEN), CARA)));
  });

  it('DENIES stats in the OTHER direction too — enforcement is symmetric', async () => {
    // Ben blocked Cara; Ben must not be able to read Cara's public stats
    // either. A one-way check here would make blocking a half-measure.
    await placeBlock(BEN, CARA);
    await assertFails(getDoc(statsRef(as(BEN), CARA)));
  });

  it('DENIES a friend request to someone who blocked you', async () => {
    await placeBlock(ANNA, CARA);
    await assertFails(
      setDoc(doc(as(CARA), 'friendRequests', `${CARA}_${ANNA}`), {
        fromUid: CARA,
        toUid: ANNA,
        participants: [CARA, ANNA],
        status: 'pending',
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('ALLOWS the blocker to lift their own block', async () => {
    await placeBlock(ANNA, BEN);
    await assertSucceeds(deleteDoc(doc(as(ANNA), 'blocks', `${ANNA}_${BEN}`)));
  });

  it('DENIES the BLOCKED party lifting the block', async () => {
    await placeBlock(ANNA, BEN);
    await assertFails(deleteDoc(doc(as(BEN), 'blocks', `${ANNA}_${BEN}`)));
  });

  it('DENIES blocking on someone else’s behalf', async () => {
    await assertFails(
      setDoc(doc(as(BEN), 'blocks', `${ANNA}_${CARA}`), {
        blockerUid: ANNA,
        blockedUid: CARA,
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES listing who has blocked YOU', async () => {
    await placeBlock(ANNA, BEN);
    await assertFails(
      getDocs(
        query(collection(as(BEN), 'blocks'), where('blockedUid', '==', BEN)),
      ),
    );
  });

  it('ALLOWS listing your OWN blocks', async () => {
    await placeBlock(ANNA, BEN);
    await assertSucceeds(
      getDocs(
        query(collection(as(ANNA), 'blocks'), where('blockerUid', '==', ANNA)),
      ),
    );
  });
});

// --- friendships ----------------------------------------------------------

describe('friendships cannot be conjured', () => {
  it('DENIES creating a friendship with NO pending request', async () => {
    // Without this, anyone could make themselves your friend and read your
    // private stats. It is the consent story of the whole social layer.
    await assertFails(
      setDoc(doc(as(BEN), 'friendships', pair(BEN, CARA)), {
        uidA: BEN < CARA ? BEN : CARA,
        uidB: BEN < CARA ? CARA : BEN,
        participants: [BEN, CARA],
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('ALLOWS the RECIPIENT to accept a real pending request', async () => {
    // Cara → Anna is pending in the seed, so Anna may create it.
    await assertSucceeds(
      setDoc(doc(as(ANNA), 'friendships', pair(ANNA, CARA)), {
        uidA: ANNA < CARA ? ANNA : CARA,
        uidB: ANNA < CARA ? CARA : ANNA,
        participants: [ANNA, CARA],
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES the SENDER accepting their own request', async () => {
    // Cara sent it; only Anna decides. The rule looks for a request addressed
    // TO the caller, so Cara finds none.
    await assertFails(
      setDoc(doc(as(CARA), 'friendships', pair(ANNA, CARA)), {
        uidA: ANNA < CARA ? ANNA : CARA,
        uidB: ANNA < CARA ? CARA : ANNA,
        participants: [ANNA, CARA],
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES a friendship at an id that is not the sorted pair', async () => {
    // A document at the wrong address is invisible to every rule that computes
    // it — which is every privacy rule.
    await assertFails(
      setDoc(doc(as(ANNA), 'friendships', `${CARA}_${ANNA}_extra`), {
        uidA: ANNA,
        uidB: CARA,
        participants: [ANNA, CARA],
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES a third party reading a friendship they are not in', async () => {
    await assertFails(getDoc(doc(as(CARA), 'friendships', pair(ANNA, BEN))));
  });

  it('ALLOWS either party to read it', async () => {
    await assertSucceeds(getDoc(doc(as(ANNA), 'friendships', pair(ANNA, BEN))));
    await assertSucceeds(getDoc(doc(as(BEN), 'friendships', pair(ANNA, BEN))));
  });

  it('ALLOWS either party to unfriend, unilaterally', async () => {
    await assertSucceeds(
      deleteDoc(doc(as(BEN), 'friendships', pair(ANNA, BEN))),
    );
  });

  it('DENIES a third party deleting someone else’s friendship', async () => {
    await assertFails(
      deleteDoc(doc(as(CARA), 'friendships', pair(ANNA, BEN))),
    );
  });

  it('DENIES enumerating the social graph', async () => {
    // Scoped list only. This is why another user's friend count is not
    // knowable from a client.
    await assertFails(
      getDocs(
        query(
          collection(as(CARA), 'friendships'),
          where('participants', 'array-contains', ANNA),
        ),
      ),
    );
  });

  it('ALLOWS listing your OWN friendships', async () => {
    await assertSucceeds(
      getDocs(
        query(
          collection(as(ANNA), 'friendships'),
          where('participants', 'array-contains', ANNA),
        ),
      ),
    );
  });
});

// --- friend requests ------------------------------------------------------

describe('friend requests', () => {
  it('ALLOWS sending one to a stranger', async () => {
    await assertSucceeds(
      setDoc(doc(as(BEN), 'friendRequests', `${BEN}_${CARA}`), {
        fromUid: BEN,
        toUid: CARA,
        participants: [BEN, CARA],
        status: 'pending',
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES forging one FROM someone else', async () => {
    await assertFails(
      setDoc(doc(as(BEN), 'friendRequests', `${CARA}_${ANNA}2`), {
        fromUid: CARA,
        toUid: ANNA,
        participants: [CARA, ANNA],
        status: 'pending',
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES an id that does not match the two parties', async () => {
    await assertFails(
      setDoc(doc(as(BEN), 'friendRequests', `${BEN}_someone_else`), {
        fromUid: BEN,
        toUid: CARA,
        participants: [BEN, CARA],
        status: 'pending',
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES creating one already `accepted`', async () => {
    await assertFails(
      setDoc(doc(as(BEN), 'friendRequests', `${BEN}_${CARA}`), {
        fromUid: BEN,
        toUid: CARA,
        participants: [BEN, CARA],
        status: 'accepted',
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('ALLOWS the RECIPIENT to reject', async () => {
    await assertSucceeds(
      updateDoc(doc(as(ANNA), 'friendRequests', `${CARA}_${ANNA}`), {
        status: 'rejected',
        decidedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES the SENDER accepting their own request', async () => {
    await assertFails(
      updateDoc(doc(as(CARA), 'friendRequests', `${CARA}_${ANNA}`), {
        status: 'accepted',
        decidedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('ALLOWS the SENDER to withdraw', async () => {
    await assertSucceeds(
      updateDoc(doc(as(CARA), 'friendRequests', `${CARA}_${ANNA}`), {
        status: 'cancelled',
        decidedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES REVIVING a rejected request to pending', async () => {
    // This is what stops "no" from being a button that does nothing: re-asking
    // requires the recipient to clear it first.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), 'friendRequests', `${CARA}_${ANNA}`),
        {
          fromUid: CARA,
          toUid: ANNA,
          participants: [CARA, ANNA],
          status: 'rejected',
        },
      );
    });
    await assertFails(
      updateDoc(doc(as(CARA), 'friendRequests', `${CARA}_${ANNA}`), {
        status: 'pending',
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES rewriting who the parties are', async () => {
    await assertFails(
      updateDoc(doc(as(ANNA), 'friendRequests', `${CARA}_${ANNA}`), {
        fromUid: BEN,
        status: 'accepted',
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES a third party reading a request', async () => {
    await assertFails(
      getDoc(doc(as(BEN), 'friendRequests', `${CARA}_${ANNA}`)),
    );
  });

  it('ALLOWS the recipient to delete a request (decline removes the row)', async () => {
    await assertSucceeds(
      deleteDoc(doc(as(ANNA), 'friendRequests', `${CARA}_${ANNA}`)),
    );
  });

  it('ALLOWS the sender to delete their own request (withdraw)', async () => {
    await assertSucceeds(
      deleteDoc(doc(as(CARA), 'friendRequests', `${CARA}_${ANNA}`)),
    );
  });

  it('DENIES a third party deleting a request they are not in', async () => {
    await assertFails(
      deleteDoc(doc(as(BEN), 'friendRequests', `${CARA}_${ANNA}`)),
    );
  });

  it('ALLOWS re-sending after the request was deleted (re-add works)', async () => {
    // The whole point of Issue 3's fix: once the declined row is gone, a fresh
    // request is a clean create, not a denied update.
    await assertSucceeds(
      deleteDoc(doc(as(ANNA), 'friendRequests', `${CARA}_${ANNA}`)),
    );
    await assertSucceeds(
      setDoc(doc(as(CARA), 'friendRequests', `${CARA}_${ANNA}`), {
        fromUid: CARA, toUid: ANNA, participants: [CARA, ANNA],
        status: 'pending', createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });
});

// --- usernames ------------------------------------------------------------

describe('usernames — uniqueness without enumeration', () => {
  it('ALLOWS resolving a handle you were given', async () => {
    await assertSucceeds(getDoc(doc(as(BEN), 'usernames', 'anna')));
  });

  it('DENIES LISTING the usernames collection', async () => {
    // The load-bearing denial. Listing here rebuilds the user-enumeration hole
    // that `users` had `list: if false` applied to close: sweep the handles,
    // get each uid, get each profile.
    await assertFails(getDocs(collection(as(BEN), 'usernames')));
  });

  it('DENIES claiming a handle someone else holds', async () => {
    await assertFails(
      setDoc(doc(as(BEN), 'usernames', 'anna'), {
        uid: BEN,
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('DENIES reserving a handle FOR someone else', async () => {
    await assertFails(
      setDoc(doc(as(BEN), 'usernames', 'brandnew'), {
        uid: CARA,
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('ALLOWS claiming a free handle for yourself', async () => {
    await assertSucceeds(
      setDoc(doc(as(BEN), 'usernames', 'benjamin'), {
        uid: BEN,
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('ALLOWS releasing a handle you hold', async () => {
    await assertSucceeds(deleteDoc(doc(as(BEN), 'usernames', 'ben')));
  });

  it('DENIES releasing someone else’s', async () => {
    await assertFails(deleteDoc(doc(as(BEN), 'usernames', 'anna')));
  });
});

// --- the profile mirror ---------------------------------------------------

describe('the username mirror on users/{uid}', () => {
  it('DENIES displaying a handle you do NOT hold', async () => {
    // Impersonation. Search is unaffected (it resolves through `usernames/`),
    // so the damage is entirely on the profile screen — which is exactly what
    // the reserved-handle list exists to prevent, defeated through another door.
    await assertFails(
      setDoc(
        doc(as(BEN), 'users', BEN),
        { name: BEN, username: 'anna' },
        { merge: true },
      ),
    );
  });

  it('ALLOWS displaying a handle you DO hold', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'usernames', 'benjamin'), { uid: BEN });
    });
    await assertSucceeds(
      setDoc(
        doc(as(BEN), 'users', BEN),
        { name: BEN, username: 'benjamin' },
        { merge: true },
      ),
    );
  });

  it('ALLOWS an unrelated profile edit without re-proving the handle', async () => {
    // The check is gated on `username` actually CHANGING. Otherwise a quiet-
    // hours edit would spend a get(), and — worse — a missing reservation would
    // deny every future write, locking the user out over a field they never
    // touched.
    await assertSucceeds(
      setDoc(
        doc(as(ANNA), 'users', ANNA),
        { name: ANNA, quietHoursStartMinutes: 1320 },
        { merge: true },
      ),
    );
  });

  it('DENIES a bio over the length cap', async () => {
    await assertFails(
      setDoc(
        doc(as(ANNA), 'users', ANNA),
        { name: ANNA, bio: 'x'.repeat(301) },
        { merge: true },
      ),
    );
  });

  it('ALLOWS a bio at the cap', async () => {
    await assertSucceeds(
      setDoc(
        doc(as(ANNA), 'users', ANNA),
        { name: ANNA, bio: 'x'.repeat(300) },
        { merge: true },
      ),
    );
  });

  it('DENIES an avatar claiming a size no storage would accept', async () => {
    await assertFails(
      setDoc(
        doc(as(ANNA), 'users', ANNA),
        {
          name: ANNA,
          avatar: {
            url: 'https://example.test/a.gif',
            storageKey: `avatars/${ANNA}/a.gif`,
            mime: 'image/gif',
            sizeBytes: 50 * 1024 * 1024,
            moderation: 'approved',
          },
        },
        { merge: true },
      ),
    );
  });

  it('ALLOWS a normal avatar', async () => {
    await assertSucceeds(
      setDoc(
        doc(as(ANNA), 'users', ANNA),
        {
          name: ANNA,
          avatar: {
            url: 'https://example.test/a.gif',
            storageKey: `avatars/${ANNA}/a.gif`,
            mime: 'image/gif',
            sizeBytes: 1024,
            moderation: 'approved',
          },
        },
        { merge: true },
      ),
    );
  });

  it('DENIES editing someone else’s profile', async () => {
    await assertFails(
      setDoc(doc(as(BEN), 'users', ANNA), { name: 'hacked' }, { merge: true }),
    );
  });
});
