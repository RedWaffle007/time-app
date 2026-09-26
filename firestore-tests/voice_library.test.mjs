// Security-rules tests for the voice-note library (item 32d, 2026-09-26).
//
// `users/{uid}/voiceLibrary/{noteId}`: only the Worker creates and deletes
// (it keeps each entry with its audio); the owner reads and may rename.
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
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
} from 'firebase/firestore';

const OWNER = 'uidB';
const OTHER = 'uidA';
const NOTE = 'note0000000000000001';
const path = `users/${OWNER}/voiceLibrary/${NOTE}`;

let testEnv;
const as = (uid) => testEnv.authenticatedContext(uid).firestore();

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-voicelibrary',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(async () => { await testEnv.cleanup(); });

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), path), {
      sha256: 'a'.repeat(64), durationMs: 7000, sizeBytes: 900, createdAt: new Date(),
    });
  });
});

describe('voice library', () => {
  it('the owner reads and lists their notes; nobody else can', async () => {
    await assertSucceeds(getDoc(doc(as(OWNER), path)));
    await assertSucceeds(getDocs(collection(as(OWNER), `users/${OWNER}/voiceLibrary`)));
    await assertFails(getDoc(doc(as(OTHER), path)));
    await assertFails(getDocs(collection(as(OTHER), `users/${OWNER}/voiceLibrary`)));
    await assertFails(getDoc(doc(testEnv.unauthenticatedContext().firestore(), path)));
  });

  it('only the Worker creates or deletes (keeps entry and audio together)', async () => {
    await assertFails(setDoc(doc(as(OWNER), `users/${OWNER}/voiceLibrary/note0000000000000002`), {
      sha256: 'b'.repeat(64), durationMs: 5000, sizeBytes: 800, createdAt: new Date(),
    }));
    await assertFails(deleteDoc(doc(as(OWNER), path)));
    await assertFails(deleteDoc(doc(as(OTHER), path)));
  });

  it('the owner renames (1–60 characters) or clears the name', async () => {
    await assertSucceeds(updateDoc(doc(as(OWNER), path), { name: 'Wake-up song' }));
    await assertSucceeds(updateDoc(doc(as(OWNER), path), { name: 'x'.repeat(60) }));
    await assertSucceeds(updateDoc(doc(as(OWNER), path), { name: deleteField() }));
    await assertFails(updateDoc(doc(as(OWNER), path), { name: '' }));
    await assertFails(updateDoc(doc(as(OWNER), path), { name: 'x'.repeat(61) }));
    await assertFails(updateDoc(doc(as(OWNER), path), { name: 42 }));
    await assertFails(updateDoc(doc(as(OTHER), path), { name: 'Mine now' }));
  });

  it('nothing but the name can change — never the audio facts', async () => {
    await assertFails(updateDoc(doc(as(OWNER), path), { sha256: 'c'.repeat(64) }));
    await assertFails(updateDoc(doc(as(OWNER), path), { durationMs: 1 }));
    await assertFails(updateDoc(doc(as(OWNER), path), { name: 'ok', createdAt: new Date(0) }));
  });
});
