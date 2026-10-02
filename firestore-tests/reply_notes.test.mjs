// Security-rules tests for R6 (2026-10-02): the target's optional note to the
// planner ("Send note" / "Dismiss & reply"; DECISIONS.md "Reply notes").
//
// World: target A, planner B (A's friend), an outsider C. Item i1 is B's plan
// for A; i2 is A's own self-plan.
//
// What only the rules can enforce, and what these prove:
//   * only the TARGET may write the note, only on someone else's plan;
//   * once, never edited or removed;
//   * 1..200 characters, server-stamped, nothing else in the same write;
//   * a note may still be written after the plan is answered (Dismiss &
//     reply on a voice note: the dismissal marks it heard first);
//   * the planner can read it; the existing target writes are untouched.
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
  deleteField,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
} from 'firebase/firestore';

const A = 'uidA'; // target
const B = 'uidB'; // planner, A's friend
const C = 'uidC'; // outsider

const sorted = (x, y) => (x < y ? `${x}_${y}` : `${y}_${x}`);
const planPath = `scheduleItems/${A}/items/i1`;
const selfPath = `scheduleItems/${A}/items/i2`;

let testEnv;
const as = (uid) => testEnv.authenticatedContext(uid).firestore();

const item = (createdByUid, extra = {}) => ({
  targetUid: A, createdByUid, groupId: '', title: 'Walk',
  localWallTime: '', timezone: 'Asia/Kolkata',
  scheduledInstantUtc: new Date('2026-10-02T10:30:00Z'),
  status: 'approved', createdAt: new Date(), updatedAt: new Date(),
  ...extra,
});

const reply = (text) => ({
  reply: { text, sentAt: serverTimestamp() },
  updatedAt: serverTimestamp(),
});

async function seed(path, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), path), data);
  });
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-replynotes',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(async () => { await testEnv.cleanup(); });

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seed(`friendships/${sorted(A, B)}`, {
    uidA: A, uidB: B, participants: [A, B], createdAt: new Date(),
  });
  await seed(planPath, item(B));
  await seed(selfPath, item(A));
});

describe('R6 reply note', () => {
  it('the target may send one note on a friend\'s plan', async () => {
    await assertSucceeds(updateDoc(doc(as(A), planPath), reply('On my way')));
  });

  it('the planner can read it', async () => {
    await assertSucceeds(updateDoc(doc(as(A), planPath), reply('On my way')));
    const snap = await assertSucceeds(getDoc(doc(as(B), planPath)));
    if (snap.data().reply.text !== 'On my way') throw new Error('not readable');
  });

  it('only once: no second note, no edit, no removal', async () => {
    await assertSucceeds(updateDoc(doc(as(A), planPath), reply('First')));
    await assertFails(updateDoc(doc(as(A), planPath), reply('Second')));
    await assertFails(updateDoc(doc(as(A), planPath), {
      reply: deleteField(), updatedAt: serverTimestamp(),
    }));
  });

  it('nobody else may write it: not the planner, not an outsider', async () => {
    await assertFails(updateDoc(doc(as(B), planPath), reply('Fake')));
    await assertFails(updateDoc(doc(as(C), planPath), reply('Fake')));
  });

  it('never on a self-plan (no planner to read it)', async () => {
    await assertFails(updateDoc(doc(as(A), selfPath), reply('Me')));
  });

  it('1 to 200 characters, never blank', async () => {
    await assertFails(updateDoc(doc(as(A), planPath), reply('')));
    await assertFails(updateDoc(doc(as(A), planPath), reply('   ')));
    await assertFails(updateDoc(doc(as(A), planPath), reply('x'.repeat(201))));
    await assertSucceeds(updateDoc(doc(as(A), planPath), reply('x'.repeat(200))));
  });

  it('server-stamped, and only text + sentAt', async () => {
    await assertFails(updateDoc(doc(as(A), planPath), {
      reply: { text: 'Hi', sentAt: new Date('2020-01-01T00:00:00Z') },
      updatedAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(doc(as(A), planPath), {
      reply: { text: 'Hi', sentAt: serverTimestamp(), from: B },
      updatedAt: serverTimestamp(),
    }));
  });

  it('written alone: never together with an outcome or anything else', async () => {
    await assertFails(updateDoc(doc(as(A), planPath), {
      ...reply('Done!'),
      outcome: { result: 'done', completedAt: serverTimestamp() },
    }));
    await assertFails(updateDoc(doc(as(A), planPath), {
      ...reply('Hi'),
      title: 'Changed',
    }));
  });

  it('still allowed once the plan is answered (Dismiss & reply)', async () => {
    await seed(planPath, item(B, {
      outcome: { result: 'done', completedAt: new Date() },
      alarm: { dismissedAt: new Date() },
    }));
    await assertSucceeds(updateDoc(doc(as(A), planPath), reply('Heard it')));
  });

  it('not on a cancelled plan', async () => {
    await seed(planPath, item(B, { status: 'withdrawn' }));
    await assertFails(updateDoc(doc(as(A), planPath), reply('Hi')));
  });

  it('the target\'s other writes cannot carry a note', async () => {
    await assertFails(updateDoc(doc(as(A), planPath), {
      outcome: { result: 'skipped', skippedAt: serverTimestamp() },
      reply: { text: 'Sorry', sentAt: serverTimestamp() },
      updatedAt: serverTimestamp(),
    }));
    // ...and still work without one (unchanged).
    await assertSucceeds(updateDoc(doc(as(A), planPath), {
      outcome: { result: 'skipped', skippedAt: serverTimestamp() },
      updatedAt: serverTimestamp(),
    }));
  });
});
