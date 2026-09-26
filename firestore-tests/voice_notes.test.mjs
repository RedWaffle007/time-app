// Security-rules tests for voice-note alarms (item 32a, 2026-09-26).
//
// The item carries only `voiceNote {durationMs, sha256, sizeBytes}`; the
// rules require it to match the `voiceUploads/{itemId}` record the Worker
// wrote after checking the audio. Only the target may stamp the delivery
// receipt, once. Nobody may touch `voiceUploads` directly.
//
// Run: npm test

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc } from 'firebase/firestore';

const A = 'uidA'; // target
const B = 'uidB'; // planner (friend with a planning grant)
const C = 'uidC'; // outsider
const PAIR = [A, B].sort().join('_');
const GRANT = `${B}_${A}`;
const ITEM = 'itemVoice000000000001';
const itemPath = `scheduleItems/${A}/items/${ITEM}`;
const SHA = 'a'.repeat(64);

let testEnv;
const as = (uid) => testEnv.authenticatedContext(uid).firestore();

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-voicenotes',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(async () => { await testEnv.cleanup(); });

async function seed({ upload = {} } = {}) {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of [A, B, C]) {
      await setDoc(doc(db, 'users', uid), { name: uid, homeTimezone: 'UTC' });
    }
    await setDoc(doc(db, 'friendships', PAIR), {
      uidA: A, uidB: B, participants: [A, B], createdAt: new Date(),
    });
    await setDoc(doc(db, `friendships/${PAIR}/plannerGrants/${GRANT}`), {
      plannerUid: B, targetUid: A, groupId: '', granted: true,
      grantedByUid: A, updatedAt: new Date(),
    });
    if (upload !== null) {
      await setDoc(doc(db, `voiceUploads/${ITEM}`), {
        uploaderUid: B, targetUid: A, sha256: SHA, durationMs: 12000,
        sizeBytes: 90000, createdAt: new Date(), expiresAt: new Date(),
        ...upload,
      });
    }
  });
}

const item = (o = {}) => ({
  targetUid: A, createdByUid: B, groupId: '', title: 'Wake up',
  localWallTime: '2026-10-01 07:00', timezone: 'UTC',
  scheduledInstantUtc: new Date('2026-10-01T07:00:00Z'),
  status: 'pending', createdAt: new Date(), updatedAt: new Date(),
  voiceNote: { durationMs: 12000, sha256: SHA, sizeBytes: 90000 },
  ...o,
});

describe('voice note on create', () => {
  beforeEach(() => seed());

  it('a granted planner attaches the note the Worker checked', async () => {
    await assertSucceeds(setDoc(doc(as(B), itemPath), item()));
  });

  it('a plan without a voice note is unchanged', async () => {
    const { voiceNote, ...plain } = item();
    await assertSucceeds(setDoc(doc(as(B), itemPath), plain));
  });

  it('DENIES a hash that does not match the checked upload', async () => {
    await assertFails(setDoc(doc(as(B), itemPath), item({
      voiceNote: { durationMs: 12000, sha256: 'b'.repeat(64), sizeBytes: 90000 },
    })));
  });

  it('DENIES malformed metadata', async () => {
    const bad = [
      { durationMs: 20501, sha256: SHA, sizeBytes: 90000 },
      { durationMs: 0, sha256: SHA, sizeBytes: 90000 },
      { durationMs: 12000, sha256: SHA, sizeBytes: 262145 },
      { durationMs: 12000, sha256: 'abc', sizeBytes: 90000 },
      { durationMs: 12000, sha256: SHA, sizeBytes: 90000, url: 'https://x' },
      { durationMs: 12000, sha256: SHA, sizeBytes: 90000, deliveredAt: new Date() },
      'not-a-map',
    ];
    for (const voiceNote of bad) {
      await assertFails(setDoc(doc(as(B), itemPath), item({ voiceNote })));
    }
  });

  it('DENIES a note with no upload record', async () => {
    await seed({ upload: null });
    await assertFails(setDoc(doc(as(B), itemPath), item()));
  });

  it('DENIES reusing an upload made by someone else, or for someone else', async () => {
    await seed({ upload: { uploaderUid: C } });
    await assertFails(setDoc(doc(as(B), itemPath), item()));
    await seed({ upload: { targetUid: C } });
    await assertFails(setDoc(doc(as(B), itemPath), item()));
  });

  it('DENIES a voice note on a self-plan', async () => {
    await seed({ upload: { uploaderUid: A } });
    await assertFails(setDoc(doc(as(A), itemPath), item({
      createdByUid: A, status: 'approved',
    })));
  });
});

describe('voiceUploads is Worker-only', () => {
  beforeEach(() => seed());

  it('nobody reads or writes it directly', async () => {
    for (const uid of [A, B, C]) {
      await assertFails(getDoc(doc(as(uid), `voiceUploads/${ITEM}`)));
      await assertFails(setDoc(doc(as(uid), `voiceUploads/${ITEM}`), {
        uploaderUid: uid, targetUid: A, sha256: SHA,
      }));
      await assertFails(setDoc(doc(as(uid), 'voiceUploads/other0000000'), {
        uploaderUid: uid, targetUid: A, sha256: SHA,
      }));
    }
  });
});

describe('delivery receipt', () => {
  beforeEach(async () => {
    await seed();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), itemPath), item({ status: 'approved' }));
    });
  });

  it('the target stamps deliveredAt once', async () => {
    await assertSucceeds(updateDoc(doc(as(A), itemPath), {
      'voiceNote.deliveredAt': new Date(), updatedAt: new Date(),
    }));
    await assertFails(updateDoc(doc(as(A), itemPath), {
      'voiceNote.deliveredAt': new Date(), updatedAt: new Date(),
    }));
  });

  it('DENIES the planner or an outsider stamping it', async () => {
    for (const uid of [B, C]) {
      await assertFails(updateDoc(doc(as(uid), itemPath), {
        'voiceNote.deliveredAt': new Date(), updatedAt: new Date(),
      }));
    }
  });

  it('DENIES changing the approved metadata or a non-timestamp stamp', async () => {
    const changes = [
      { 'voiceNote.sha256': 'c'.repeat(64) },
      { 'voiceNote.durationMs': 1 },
      { 'voiceNote.deliveredAt': 'yesterday' },
      { voiceNote: { deliveredAt: new Date() } },
    ];
    for (const change of changes) {
      await assertFails(updateDoc(doc(as(A), itemPath), {
        ...change, updatedAt: new Date(),
      }));
    }
  });

  it('DENIES a receipt on an item that has no voice note', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const { voiceNote, ...plain } = item({ status: 'approved' });
      await setDoc(doc(ctx.firestore(), itemPath), plain);
    });
    await assertFails(updateDoc(doc(as(A), itemPath), {
      'voiceNote.deliveredAt': new Date(), updatedAt: new Date(),
    }));
  });

  it('a voice note never blocks Done', async () => {
    await assertSucceeds(updateDoc(doc(as(A), itemPath), {
      outcome: { result: 'done', completedAt: new Date() },
      updatedAt: new Date(),
    }));
  });
});

describe('a voice note never blocks the approval decision', () => {
  it('the target approves a pending voice plan', async () => {
    await seed();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), itemPath), item());
    });
    await assertSucceeds(updateDoc(doc(as(A), itemPath), {
      status: 'approved', decidedAt: new Date(), updatedAt: new Date(),
    }));
  });
});
