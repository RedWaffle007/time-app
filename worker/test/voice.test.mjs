import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import worker, { VOICE_SWEEP_CRON, cronJobFor } from '../src/index.js';
import { makeFirestoreDb } from '../src/firestore-rest.js';
import {
  MAX_VOICE_BYTES,
  ORPHAN_TTL_MS,
  RETAIN_AFTER_DUE_MS,
  callerMayPlanFor,
  mp4DurationMs,
  objectKey,
  sha256Hex,
  sniffM4a,
  sweepVoiceUploads,
  voiceDownload,
  voiceUpload,
} from '../src/voice.js';

// ---------------------------------------------------------------- a real .m4a skeleton

function box(type, payload) {
  const out = new Uint8Array(8 + payload.length);
  new DataView(out.buffer).setUint32(0, out.length);
  out.set([...type].map((c) => c.charCodeAt(0)), 4);
  out.set(payload, 8);
  return out;
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

function mvhd({ version = 0, timescale = 1000, duration = 12000 } = {}) {
  const body = new Uint8Array(version === 0 ? 100 : 112);
  const view = new DataView(body.buffer);
  body[0] = version;
  if (version === 0) {
    view.setUint32(12, timescale);
    view.setUint32(16, duration);
  } else {
    view.setUint32(20, timescale);
    view.setUint32(24, 0);
    view.setUint32(28, duration);
  }
  return box('mvhd', body);
}

function m4a({ brand = 'M4A ', ms = 12000, version = 0, pad = 0, noMoov = false } = {}) {
  const ftyp = box('ftyp', new Uint8Array([...brand].map((c) => c.charCodeAt(0)).concat([0, 0, 0, 0])));
  const mdat = box('mdat', new Uint8Array(pad));
  if (noMoov) return concat(ftyp, mdat);
  return concat(ftyp, mdat, box('moov', mvhd({ version, timescale: 44100, duration: Math.round(ms * 44.1) })));
}

// ---------------------------------------------------------------- format checks

test('only MPEG-4 audio containers pass the byte sniff', () => {
  assert.equal(sniffM4a(m4a()), true);
  for (const brand of ['mp42', 'isom', 'mp41']) assert.equal(sniffM4a(m4a({ brand })), true);
  assert.equal(sniffM4a(m4a({ brand: 'qt  ' })), false);
  assert.equal(sniffM4a(new TextEncoder().encode('<html>not audio</html>')), false);
  assert.equal(sniffM4a(new Uint8Array([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0, 0, 0])), false); // MP3 ID3
  assert.equal(sniffM4a(new Uint8Array(4)), false);
});

test('duration comes from the file header, v0 and v1, moov anywhere', () => {
  assert.equal(mp4DurationMs(m4a({ ms: 12000 })), 12000);
  assert.equal(mp4DurationMs(m4a({ ms: 20000, version: 1 })), 20000);
  assert.equal(mp4DurationMs(m4a({ noMoov: true })), null);
  // Truncated / lying box sizes never read past the buffer.
  const broken = m4a();
  new DataView(broken.buffer).setUint32(broken.length - 108, 999999);
  assert.equal(mp4DurationMs(broken), null);
});

// ---------------------------------------------------------------- upload

function harness(docs = {}, { putOk = true, stored = {} } = {}) {
  const store = {
    'friendships/A_B': { participants: ['A', 'B'] },
    'friendships/A_B/plannerGrants/B_A': { granted: true },
    ...docs,
  };
  const objects = { ...stored };
  const patched = [];
  const deleted = [];
  const removedObjects = [];
  return {
    store, objects, patched, deleted, removedObjects,
    ctx: {
      now: new Date('2026-10-01T00:00:00Z'),
      db: {
        getDoc: async (path) => store[path] ?? null,
        patchDoc: async (path, fields) => { patched.push({ path, fields }); store[path] = { ...(store[path] || {}), ...fields }; },
        deleteDoc: async (path) => { deleted.push(path); delete store[path]; },
      },
      storage: {
        put: async (key, bytes) => { if (putOk) objects[key] = bytes; return putOk; },
        get: async (key) => objects[key] ?? null,
        delete: async (key) => { removedObjects.push(key); delete objects[key]; return true; },
      },
    },
  };
}

const ITEM = 'item0000000000000001';
const upload = (h, o = {}) => voiceUpload(h.ctx, {
  callerUid: 'B', targetUid: 'A', itemId: ITEM, groupId: '', bytes: m4a(), ...o,
});

test('a granted planner uploads; the Worker records what it checked', async () => {
  const h = harness();
  const res = await upload(h);
  assert.equal(res.status, 200);
  assert.equal(res.body.durationMs, 12000);
  assert.equal(res.body.sha256, await sha256Hex(m4a()));
  assert.ok(h.objects[objectKey('A', ITEM)]);
  const record = h.store[`voiceUploads/${ITEM}`];
  assert.equal(record.uploaderUid, 'B');
  assert.equal(record.targetUid, 'A');
  assert.equal(record.sha256, res.body.sha256);
  assert.equal(record.expiresAt.getTime(), h.ctx.now.getTime() + ORPHAN_TTL_MS);
});

test('the emergency grant or a group grant also allows it', async () => {
  const emergency = harness({
    'friendships/A_B/plannerGrants/B_A': null,
    'friendships/A_B/emergencyGrants/B_A': { granted: true },
  });
  assert.equal((await upload(emergency)).status, 200);
  const group = harness({
    'friendships/A_B': null,
    'friendships/A_B/plannerGrants/B_A': null,
    'groups/group00000001/plannerGrants/B_A': { granted: true },
  });
  assert.equal((await upload(group, { groupId: 'group00000001' })).status, 200);
});

test('no permission, a revoked grant, or an ended friendship is refused', async () => {
  const cases = [
    harness({ 'friendships/A_B/plannerGrants/B_A': { granted: false } }),
    harness({ 'friendships/A_B': null }),
    harness({ 'friendships/A_B/plannerGrants/B_A': null }),
  ];
  for (const h of cases) {
    const res = await upload(h);
    assert.equal(res.status, 403);
    assert.equal(Object.keys(h.objects).length, 0, 'nothing stored');
  }
  // A group id without a group grant falls back to friendship only.
  assert.equal(await callerMayPlanFor(harness({ 'friendships/A_B': null }).ctx.db, 'B', 'A', 'group00000001'), false);
});

test('bad audio is refused before anything is stored', async () => {
  const cases = [
    [new Uint8Array(0), 400, 'empty'],
    [new Uint8Array(MAX_VOICE_BYTES + 1), 413, 'too-large'],
    [new TextEncoder().encode('<script>alert(1)</script>'), 415, 'unsupported-type'],
    [m4a({ noMoov: true }), 415, 'unreadable-audio'],
    [m4a({ ms: 20600 }), 413, 'too-long'],
    [m4a({ ms: 100 }), 400, 'too-short'],
  ];
  for (const [bytes, status, error] of cases) {
    const h = harness();
    const res = await upload(h, { bytes });
    assert.deepEqual([res.status, res.body.error], [status, error]);
    assert.equal(Object.keys(h.objects).length, 0);
  }
});

test('self-plans, malformed ids and existing plans are refused', async () => {
  assert.equal((await upload(harness(), { callerUid: 'A' })).status, 403);
  assert.equal((await upload(harness(), { itemId: '../../x' })).status, 400);
  assert.equal((await upload(harness(), { targetUid: 'a/b' })).status, 400);
  const existing = harness({ [`scheduleItems/A/items/${ITEM}`]: { targetUid: 'A' } });
  const res = await upload(existing);
  assert.equal(res.status, 409, 'immutable once the plan exists');
  assert.equal(Object.keys(existing.objects).length, 0);
});

test('re-recording before saving replaces your own upload, never someone else\'s', async () => {
  const h = harness();
  await upload(h);
  const again = await upload(h, { bytes: m4a({ ms: 8000 }) });
  assert.equal(again.status, 200);
  assert.equal(h.store[`voiceUploads/${ITEM}`].durationMs, 8000);

  const other = harness({ [`voiceUploads/${ITEM}`]: { uploaderUid: 'C', targetUid: 'A' } });
  assert.equal((await upload(other)).status, 403);
});

test('a storage failure reports, and writes no record', async () => {
  const h = harness({}, { putOk: false });
  const res = await upload(h);
  assert.equal(res.status, 502);
  assert.equal(h.store[`voiceUploads/${ITEM}`], undefined);
});

// ---------------------------------------------------------------- download

async function withItem(extra = {}, stored) {
  const bytes = m4a();
  const sha256 = await sha256Hex(bytes);
  return harness({
    [`scheduleItems/A/items/${ITEM}`]: {
      targetUid: 'A', createdByUid: 'B', voiceNote: { sha256, durationMs: 12000 }, ...extra,
    },
  }, { stored: stored === undefined ? { [objectKey('A', ITEM)]: bytes } : stored });
}

test('the target and the planner download the exact approved bytes', async () => {
  for (const callerUid of ['A', 'B']) {
    const h = await withItem();
    const res = await voiceDownload(h.ctx, { callerUid, targetUid: 'A', itemId: ITEM });
    assert.equal(res.status, 200);
    assert.deepEqual(res.bytes, m4a());
  }
});

test('downloads fail closed', async () => {
  const outsider = await withItem();
  assert.equal((await voiceDownload(outsider.ctx, { callerUid: 'C', targetUid: 'A', itemId: ITEM })).status, 403);
  assert.equal((await voiceDownload(harness().ctx, { callerUid: 'A', targetUid: 'A', itemId: ITEM })).status, 404);
  const noNote = await withItem({ voiceNote: undefined });
  assert.equal((await voiceDownload(noNote.ctx, { callerUid: 'A', targetUid: 'A', itemId: ITEM })).status, 404);
  const gone = await withItem({}, {});
  assert.equal((await voiceDownload(gone.ctx, { callerUid: 'A', targetUid: 'A', itemId: ITEM })).status, 410);
  const tampered = await withItem({}, { [objectKey('A', ITEM)]: m4a({ ms: 5000 }) });
  assert.equal((await voiceDownload(tampered.ctx, { callerUid: 'A', targetUid: 'A', itemId: ITEM })).status, 409);
  assert.equal((await voiceDownload(outsider.ctx, { callerUid: 'A', targetUid: 'A', itemId: 'x/y' })).status, 400);
});

// ---------------------------------------------------------------- cleanup

function sweepHarness(rows, docs, deleteOk = true) {
  const h = harness(docs);
  h.ctx.db.listDueVoiceUploads = async () => rows;
  if (!deleteOk) h.ctx.storage.delete = async () => false;
  return h;
}

test('an upload that never became a plan is deleted', async () => {
  const h = sweepHarness([{ id: ITEM, data: { targetUid: 'A', sha256: 'x' } }], {});
  const summary = await sweepVoiceUploads(h.ctx, new Date('2026-10-02T00:00:00Z'));
  assert.equal(summary.deleted, 1);
  assert.deepEqual(h.removedObjects, [objectKey('A', ITEM)]);
  assert.deepEqual(h.deleted, [`voiceUploads/${ITEM}`]);
});

test('a used note is kept until 7 days after its plan, then deleted', async () => {
  const scheduled = '2026-10-01T07:00:00.000Z';
  const docs = {
    [`scheduleItems/A/items/${ITEM}`]: { voiceNote: { sha256: 'h' }, scheduledInstantUtc: scheduled },
  };
  const row = [{ id: ITEM, data: { targetUid: 'A', sha256: 'h' } }];
  const early = sweepHarness(row, docs);
  const s1 = await sweepVoiceUploads(early.ctx, new Date('2026-10-02T00:00:00Z'));
  assert.equal(s1.extended, 1);
  assert.equal(early.removedObjects.length, 0);
  assert.equal(
    early.patched[0].fields.expiresAt.getTime(),
    Date.parse(scheduled) + RETAIN_AFTER_DUE_MS,
  );

  const late = sweepHarness(row, docs);
  const s2 = await sweepVoiceUploads(late.ctx, new Date('2026-10-09T00:00:00Z'));
  assert.equal(s2.deleted, 1);
});

test('a plan saved WITHOUT this upload leaves it an orphan', async () => {
  const h = sweepHarness(
    [{ id: ITEM, data: { targetUid: 'A', sha256: 'old' } }],
    { [`scheduleItems/A/items/${ITEM}`]: { voiceNote: { sha256: 'new' }, scheduledInstantUtc: '2030-01-01T00:00:00Z' } },
  );
  const summary = await sweepVoiceUploads(h.ctx, new Date('2026-10-02T00:00:00Z'));
  assert.equal(summary.deleted, 1);
});

test('a failed storage delete keeps the record, so the next sweep retries', async () => {
  const h = sweepHarness([{ id: ITEM, data: { targetUid: 'A', sha256: 'x' } }], {}, false);
  const summary = await sweepVoiceUploads(h.ctx, new Date('2026-10-02T00:00:00Z'));
  assert.equal(summary.deleted, 0);
  assert.deepEqual(h.deleted, []);
});

// ---------------------------------------------------------------- routes + wiring

const env = { PROJECT_ID: 'demo', SUPABASE_URL: 'https://x.supabase.co', SUPABASE_VOICE_BUCKET: 'voice-notes', SUPABASE_SERVICE_KEY: 'k' };

test('voice routes check method, size and auth before anything else', async () => {
  const req = (path, init) => new Request(`https://w.example${path}`, init);
  assert.equal((await worker.fetch(req('/voice', { method: 'GET' }), env)).status, 405);
  assert.equal((await worker.fetch(req(`/voice/A/${ITEM}`, { method: 'POST' }), env)).status, 405);
  assert.equal((await worker.fetch(req('/voice', {
    method: 'POST', headers: { 'content-length': String(MAX_VOICE_BYTES + 1) }, body: 'x',
  }), env)).status, 413);
  assert.equal((await worker.fetch(req('/voice', { method: 'POST', body: 'x' }), env)).status, 401);
  assert.equal((await worker.fetch(req(`/voice/A/${ITEM}`), env)).status, 401);
  const unconfigured = await worker.fetch(req('/voice', { method: 'POST', body: 'x' }), { PROJECT_ID: 'demo' });
  assert.equal(unconfigured.status, 500);
});

test('the hourly sweep cron and the private bucket are configured', () => {
  assert.equal(cronJobFor(VOICE_SWEEP_CRON), 'voiceSweep');
  const toml = readFileSync(new URL('../wrangler.toml', import.meta.url), 'utf8');
  assert.match(toml, /SUPABASE_VOICE_BUCKET = "voice-notes"/);
  assert.ok(toml.includes('"7 * * * *"'));
});

test('whole numbers are written as Firestore integers', async () => {
  const original = globalThis.fetch;
  let body;
  globalThis.fetch = async (_url, init) => { body = JSON.parse(init.body); return new Response('{}'); };
  try {
    await makeFirestoreDb('p', 't').patchDoc('voiceUploads/x', { durationMs: 12000, ratio: 0.5 });
  } finally {
    globalThis.fetch = original;
  }
  assert.deepEqual(body.fields.durationMs, { integerValue: '12000' });
  assert.deepEqual(body.fields.ratio, { doubleValue: 0.5 });
});
