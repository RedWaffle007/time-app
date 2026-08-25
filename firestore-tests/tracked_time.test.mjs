// Security-rules tests for personal time-tracking:
// users/{uid}/trackedTime/{entryId}.
//
// What matters here is exactly what the client cannot enforce:
//
//   * owner-only in BOTH directions — a stranger can neither read nor write
//     another user's tracked time (unlike profileStats, reads are NOT opened);
//   * the one-day cap: durationMinutes must be an int in 1..1440, so no single
//     stored entry can ever exceed a day;
//   * required fields and shapes (taskName, logDate), and the both-or-neither
//     time-of-day range;
//   * the optional sourceItemId is accepted as any string and NOT verified.
//
// Run: npm test

import { readFileSync } from 'node:fs';
import { after, before, describe, it } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { deleteDoc, doc, getDoc, setDoc } from 'firebase/firestore';

const OWNER = 'uidOwner';
const STRANGER = 'uidStranger';

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-tracked-time',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});

after(async () => { await testEnv.cleanup(); });

const as = (uid) => testEnv.authenticatedContext(uid).firestore();
const entryRef = (db, uid, id) =>
  doc(db, `users/${uid}/trackedTime/${id}`);

/** A minimal valid entry payload. */
const valid = (over = {}) => ({
  taskName: 'walking',
  durationMinutes: 30,
  logDate: '2026-08-25',
  ...over,
});

/** Seed an entry bypassing rules, so read/update/delete tests have a target. */
async function seedEntry(uid, id, data = valid()) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(entryRef(ctx.firestore(), uid, id), {
      ...data, createdAt: new Date(), updatedAt: new Date(),
    });
  });
}

describe('trackedTime — ownership', () => {
  it('owner can create a valid entry', async () => {
    await assertSucceeds(setDoc(entryRef(as(OWNER), OWNER, 'e1'), valid()));
  });

  it('owner can read, update and delete their own entry', async () => {
    await seedEntry(OWNER, 'e2');
    await assertSucceeds(getDoc(entryRef(as(OWNER), OWNER, 'e2')));
    await assertSucceeds(
      setDoc(entryRef(as(OWNER), OWNER, 'e2'), valid({ durationMinutes: 45 })));
    await assertSucceeds(deleteDoc(entryRef(as(OWNER), OWNER, 'e2')));
  });

  it('a stranger can neither read nor write the owner’s entries', async () => {
    await seedEntry(OWNER, 'e3');
    await assertFails(getDoc(entryRef(as(STRANGER), OWNER, 'e3')));
    await assertFails(
      setDoc(entryRef(as(STRANGER), OWNER, 'e4'), valid()));
    await assertFails(deleteDoc(entryRef(as(STRANGER), OWNER, 'e3')));
  });
});

describe('trackedTime — the one-day cap and validation', () => {
  it('rejects durationMinutes > 1440 (more than a day)', async () => {
    await assertFails(
      setDoc(entryRef(as(OWNER), OWNER, 'c1'), valid({ durationMinutes: 1441 })));
  });

  it('accepts exactly 1440 (a full day)', async () => {
    await assertSucceeds(
      setDoc(entryRef(as(OWNER), OWNER, 'c2'), valid({ durationMinutes: 1440 })));
  });

  it('rejects durationMinutes < 1 and non-integer', async () => {
    await assertFails(
      setDoc(entryRef(as(OWNER), OWNER, 'c3'), valid({ durationMinutes: 0 })));
    await assertFails(
      setDoc(entryRef(as(OWNER), OWNER, 'c4'), valid({ durationMinutes: 30.5 })));
  });

  it('rejects an empty or over-long taskName', async () => {
    await assertFails(
      setDoc(entryRef(as(OWNER), OWNER, 'c5'), valid({ taskName: '' })));
    await assertFails(
      setDoc(entryRef(as(OWNER), OWNER, 'c6'), valid({ taskName: 'x'.repeat(201) })));
  });

  it('rejects a malformed logDate', async () => {
    await assertFails(
      setDoc(entryRef(as(OWNER), OWNER, 'c7'), valid({ logDate: '2026-8-5' })));
  });

  it('rejects an unknown extra field', async () => {
    await assertFails(
      setDoc(entryRef(as(OWNER), OWNER, 'c8'), valid({ mood: 'great' })));
  });
});

describe('trackedTime — optional fields', () => {
  it('accepts a both-halves time-of-day range', async () => {
    await assertSucceeds(setDoc(entryRef(as(OWNER), OWNER, 'r1'),
      valid({ startLocal: '14:00', endLocal: '15:00' })));
  });

  it('rejects a half range (start without end)', async () => {
    await assertFails(setDoc(entryRef(as(OWNER), OWNER, 'r2'),
      valid({ startLocal: '14:00' })));
  });

  it('accepts an unverified sourceItemId soft link', async () => {
    await assertSucceeds(setDoc(entryRef(as(OWNER), OWNER, 'r3'),
      valid({ sourceItemId: 'any-string-never-checked' })));
  });
});
