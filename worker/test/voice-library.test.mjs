import assert from 'node:assert/strict';
import test from 'node:test';

import worker from '../src/index.js';
import { objectKey, sha256Hex, sweepVoiceUploads } from '../src/voice.js';
import {
  LIBRARY_LIMIT,
  libraryAttach,
  libraryDelete,
  libraryDownload,
  libraryKey,
  saveSentVoiceNote,
} from '../src/voice-library.js';

// Item 32d (2026-09-26): every SENT voice note is kept in its planner's
// library, capped at 20 first-in-first-out; play/delete/attach are owner-only.

const AUDIO = new Uint8Array(Array.from({ length: 900 }, (_, i) => (i * 7) % 256));
const OTHER = new Uint8Array(Array.from({ length: 700 }, (_, i) => (i * 3) % 256));
const ITEM = 'item0000000000000001';
const T0 = new Date('2026-10-01T00:00:00Z');

function harness(docs = {}, objects = {}, { deleteOk = true } = {}) {
  const store = {
    'friendships/A_B': { participants: ['A', 'B'] },
    'friendships/A_B/plannerGrants/B_A': { granted: true },
    ...docs,
  };
  const bucket = { ...objects };
  return {
    store,
    bucket,
    ctx: {
      now: T0,
      db: {
        getDoc: async (path) => store[path] ?? null,
        patchDoc: async (path, fields) => { store[path] = { ...(store[path] || {}), ...fields }; },
        deleteDoc: async (path) => { delete store[path]; },
        listDocs: async (collection) => Object.entries(store)
          .filter(([p, v]) => v && p.startsWith(`${collection}/`)
            && !p.slice(collection.length + 1).includes('/'))
          .map(([p, data]) => ({ id: p.split('/').pop(), data })),
      },
      storage: {
        put: async (key, bytes) => { bucket[key] = bytes; return true; },
        get: async (key) => bucket[key] ?? null,
        delete: async (key) => { if (!deleteOk) return false; delete bucket[key]; return true; },
      },
    },
  };
}

async function sentPlan(itemId = ITEM, bytes = AUDIO) {
  const sha256 = await sha256Hex(bytes);
  const item = {
    targetUid: 'A', createdByUid: 'B', status: 'approved',
    voiceNote: { sha256, durationMs: 7000, sizeBytes: bytes.length },
  };
  return {
    item,
    docs: {
      [`scheduleItems/A/items/${itemId}`]: item,
      [`voiceUploads/${itemId}`]: { uploaderUid: 'B', targetUid: 'A', sha256, durationMs: 7000, sizeBytes: bytes.length },
    },
    objects: { [objectKey('A', itemId)]: bytes },
  };
}

const libraryEntries = (h) => Object.keys(h.store).filter((p) => p.startsWith('users/B/voiceLibrary/'));

// ---------------------------------------------------------------- saving

test('a sent voice note is copied into its planner\'s library', async () => {
  const plan = await sentPlan();
  const h = harness(plan.docs, plan.objects);
  const out = await saveSentVoiceNote(h.ctx, { targetUid: 'A', itemId: ITEM, item: plan.item }, T0);
  assert.equal(out, 'saved');
  assert.deepEqual(h.bucket[libraryKey('B', ITEM)], AUDIO);
  const entry = h.store[`users/B/voiceLibrary/${ITEM}`];
  assert.equal(entry.sha256, plan.item.voiceNote.sha256);
  assert.equal(entry.durationMs, 7000);
  assert.equal(entry.sizeBytes, AUDIO.length);
  assert.equal(entry.createdAt, T0);
  assert.equal(entry.name, undefined, 'unnamed: shows its localized date');
  assert.equal(h.store[`voiceUploads/${ITEM}`].librarySavedAt, T0);
});

test('saving is idempotent, and a deleted note is never re-added', async () => {
  const plan = await sentPlan();
  const h = harness(plan.docs, plan.objects);
  await saveSentVoiceNote(h.ctx, { targetUid: 'A', itemId: ITEM, item: plan.item }, T0);
  assert.equal(await saveSentVoiceNote(h.ctx, { targetUid: 'A', itemId: ITEM, item: plan.item }), 'already-saved');
  await libraryDelete(h.ctx, { callerUid: 'B', noteId: ITEM });
  assert.equal(await saveSentVoiceNote(h.ctx, { targetUid: 'A', itemId: ITEM, item: plan.item }), 'already-saved');
  assert.deepEqual(libraryEntries(h), []);
});

test('the same audio is not saved twice (e.g. attached from the library)', async () => {
  const plan = await sentPlan();
  const h = harness({
    ...plan.docs,
    'users/B/voiceLibrary/older00000000000001': { sha256: plan.item.voiceNote.sha256, createdAt: T0 },
  }, plan.objects);
  assert.equal(await saveSentVoiceNote(h.ctx, { targetUid: 'A', itemId: ITEM, item: plan.item }), 'duplicate');
  assert.equal(libraryEntries(h).length, 1);
});

test('self-plans, note-less plans and mismatched records are not saved', async () => {
  const plan = await sentPlan();
  const cases = [
    { ...plan.item, createdByUid: 'A' },
    { ...plan.item, voiceNote: undefined },
  ];
  for (const item of cases) {
    const h = harness(plan.docs, plan.objects);
    assert.notEqual(await saveSentVoiceNote(h.ctx, { targetUid: 'A', itemId: ITEM, item }), 'saved');
    assert.deepEqual(libraryEntries(h), []);
  }
  const forged = harness({ ...plan.docs, [`voiceUploads/${ITEM}`]: { uploaderUid: 'C', sha256: plan.item.voiceNote.sha256 } }, plan.objects);
  assert.equal(await saveSentVoiceNote(forged.ctx, { targetUid: 'A', itemId: ITEM, item: plan.item }), 'no-upload');
  const damaged = harness(plan.docs, { [objectKey('A', ITEM)]: OTHER });
  assert.equal(await saveSentVoiceNote(damaged.ctx, { targetUid: 'A', itemId: ITEM, item: plan.item }), 'audio-missing');
});

test('the 21st note pushes the oldest out — first in, first out', async () => {
  assert.equal(LIBRARY_LIMIT, 20);
  const docs = {};
  const objects = {};
  for (let i = 0; i < 20; i += 1) {
    const id = `old${String(i).padStart(17, '0')}`;
    docs[`users/B/voiceLibrary/${id}`] = { sha256: `${i}`.padStart(64, 'f'), createdAt: new Date(T0.getTime() - (20 - i) * 60000) };
    objects[libraryKey('B', id)] = OTHER;
  }
  const plan = await sentPlan();
  const h = harness({ ...docs, ...plan.docs }, { ...objects, ...plan.objects });
  assert.equal(await saveSentVoiceNote(h.ctx, { targetUid: 'A', itemId: ITEM, item: plan.item }, T0), 'saved');
  const left = libraryEntries(h);
  assert.equal(left.length, 20);
  assert.ok(!left.includes('users/B/voiceLibrary/old00000000000000000'), 'the oldest went');
  assert.equal(h.bucket[libraryKey('B', 'old00000000000000000')], undefined, 'with its audio');
  assert.ok(left.includes('users/B/voiceLibrary/old00000000000000001'));
  assert.ok(left.includes(`users/B/voiceLibrary/${ITEM}`));
});

test('an eviction whose audio will not delete keeps its entry for next time', async () => {
  const docs = {};
  for (let i = 0; i < 20; i += 1) {
    docs[`users/B/voiceLibrary/old${String(i).padStart(17, '0')}`] = { sha256: `${i}`.padStart(64, 'f'), createdAt: new Date(T0.getTime() - (20 - i) * 60000) };
  }
  const plan = await sentPlan();
  const h = harness({ ...docs, ...plan.docs }, plan.objects, { deleteOk: false });
  await saveSentVoiceNote(h.ctx, { targetUid: 'A', itemId: ITEM, item: plan.item }, T0);
  assert.equal(libraryEntries(h).length, 21);
});

test('the hourly sweep saves a used note the send-time save missed', async () => {
  const plan = await sentPlan();
  const h = harness({
    ...plan.docs,
    [`scheduleItems/A/items/${ITEM}`]: { ...plan.item, scheduledInstantUtc: '2026-10-02T00:00:00Z' },
  }, plan.objects);
  h.ctx.db.listDueVoiceUploads = async () => [{ id: ITEM, data: h.store[`voiceUploads/${ITEM}`] }];
  h.ctx.saveToLibrary = (args, at) => saveSentVoiceNote(h.ctx, args, at);
  await sweepVoiceUploads(h.ctx, T0);
  assert.ok(h.store[`users/B/voiceLibrary/${ITEM}`]);
});

// ---------------------------------------------------------------- play / delete

test('only the owner plays a note, and only the exact bytes', async () => {
  const sha256 = await sha256Hex(AUDIO);
  const docs = { [`users/B/voiceLibrary/${ITEM}`]: { sha256, durationMs: 7000 } };
  const h = harness(docs, { [libraryKey('B', ITEM)]: AUDIO });
  const mine = await libraryDownload(h.ctx, { callerUid: 'B', noteId: ITEM });
  assert.equal(mine.status, 200);
  assert.deepEqual(mine.bytes, AUDIO);
  assert.equal((await libraryDownload(h.ctx, { callerUid: 'A', noteId: ITEM })).status, 404);
  assert.equal((await libraryDownload(h.ctx, { callerUid: 'B', noteId: '../x' })).status, 400);
  const swapped = harness(docs, { [libraryKey('B', ITEM)]: OTHER });
  assert.equal((await libraryDownload(swapped.ctx, { callerUid: 'B', noteId: ITEM })).status, 409);
});

test('delete removes the audio, then the entry; never someone else\'s', async () => {
  const docs = { [`users/B/voiceLibrary/${ITEM}`]: { sha256: 'x' } };
  const h = harness(docs, { [libraryKey('B', ITEM)]: AUDIO });
  assert.deepEqual((await libraryDelete(h.ctx, { callerUid: 'A', noteId: ITEM })).body, { deleted: false });
  assert.ok(h.bucket[libraryKey('B', ITEM)], 'A cannot touch B\'s note');
  assert.deepEqual((await libraryDelete(h.ctx, { callerUid: 'B', noteId: ITEM })).body, { deleted: true });
  assert.equal(h.bucket[libraryKey('B', ITEM)], undefined);
  assert.equal(h.store[`users/B/voiceLibrary/${ITEM}`], undefined);

  const stuck = harness(docs, { [libraryKey('B', ITEM)]: AUDIO }, { deleteOk: false });
  assert.equal((await libraryDelete(stuck.ctx, { callerUid: 'B', noteId: ITEM })).status, 502);
  assert.ok(stuck.store[`users/B/voiceLibrary/${ITEM}`], 'entry kept while its audio exists');
});

// ---------------------------------------------------------------- attach

const NOTE = 'note0000000000000001';
async function attachHarness(extra = {}) {
  const sha256 = await sha256Hex(AUDIO);
  return harness(
    { [`users/B/voiceLibrary/${NOTE}`]: { sha256, durationMs: 7000 }, ...extra },
    { [libraryKey('B', NOTE)]: AUDIO },
  );
}
const attach = (h, o = {}) => libraryAttach(h.ctx, {
  callerUid: 'B', noteId: NOTE, targetUid: 'A', itemId: ITEM, groupId: '', ...o,
});

test('attaching copies the note to the plan and records it like an upload', async () => {
  const h = await attachHarness();
  const res = await attach(h);
  assert.equal(res.status, 200);
  assert.equal(res.body.sha256, await sha256Hex(AUDIO));
  assert.equal(res.body.durationMs, 7000);
  assert.deepEqual(h.bucket[objectKey('A', ITEM)], AUDIO);
  const record = h.store[`voiceUploads/${ITEM}`];
  assert.equal(record.uploaderUid, 'B');
  assert.equal(record.targetUid, 'A');
  assert.equal(record.sha256, res.body.sha256);
  assert.ok(record.librarySavedAt, 'from the library: never saved back into it');
});

test('attach is refused without permission, for yourself, or when not yours', async () => {
  assert.equal((await attach(await attachHarness({ 'friendships/A_B/plannerGrants/B_A': null }))).status, 403);
  assert.equal((await attach(await attachHarness(), { targetUid: 'B' })).status, 403);
  assert.equal((await attach(await attachHarness(), { callerUid: 'C' })).status, 404);
  assert.equal((await attach(await attachHarness({ [`scheduleItems/A/items/${ITEM}`]: { targetUid: 'A' } }))).status, 409);
  assert.equal((await attach(await attachHarness({ [`voiceUploads/${ITEM}`]: { uploaderUid: 'C', targetUid: 'A' } }))).status, 403);
  assert.equal((await attach(await attachHarness(), { noteId: 'bad/id' })).status, 400);
});

test('a fresh recording after an attach is saved again (the mark is cleared)', async () => {
  const src = (await import('node:fs')).readFileSync(new URL('../src/voice.js', import.meta.url), 'utf8');
  assert.match(src, /librarySavedAt: null/);
});

// ---------------------------------------------------------------- routes

test('library routes check the method and auth', async () => {
  const env = { PROJECT_ID: 'demo', SUPABASE_URL: 'https://x.supabase.co', SUPABASE_VOICE_BUCKET: 'voice-notes', SUPABASE_SERVICE_KEY: 'k' };
  const req = (path, init) => new Request(`https://w.example${path}`, init);
  assert.equal((await worker.fetch(req('/voice/attach', { method: 'GET' }), env)).status, 405);
  assert.equal((await worker.fetch(req(`/voice/library/${NOTE}`, { method: 'POST' }), env)).status, 405);
  assert.equal((await worker.fetch(req(`/voice/library/${NOTE}`), env)).status, 401);
  assert.equal((await worker.fetch(req(`/voice/library/${NOTE}`, { method: 'DELETE' }), env)).status, 401);
  assert.equal((await worker.fetch(req('/voice/attach', { method: 'POST' }), env)).status, 401);
});

test('the save runs at send time and in the hourly sweep, never failing the push', async () => {
  const { readFileSync } = await import('node:fs');
  const index = readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
  const notify = index.slice(index.indexOf('sendEventNotification(ctx, { event, targetUid, itemId })'));
  assert.match(notify.slice(0, 900), /event === 'created' && item\.voiceNote/);
  assert.match(notify.slice(0, 900), /saveSentVoiceNote\(/);
  assert.match(notify.slice(0, 900), /catch \(e\)/);
  assert.match(index, /ctx\.saveToLibrary = \(args, at\) => saveSentVoiceNote\(ctx, args, at\)/);
});
