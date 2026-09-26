// Voice-note alarms — storage and checks (item 32a, 2026-09-26).
//
// Audio never touches Firestore or a notification. It lives in the PRIVATE
// Supabase bucket `voice-notes`, reachable only through this Worker:
//
//   POST /voice                       upload for a plan about to be created
//        headers: x-target-uid, x-item-id, [x-group-id]; body = the .m4a
//   GET  /voice/{targetUid}/{itemId}  download (the target or the planner)
//   /voice/library/…, /voice/attach   the planner's library (voice-library.js)
//
// Every check is made HERE against the bytes and against Firestore; nothing
// the phone claims is trusted. The item then carries only
// `voiceNote {durationMs, sha256, sizeBytes}`, and the Firestore rules require
// it to match the `voiceUploads/{itemId}` record this Worker wrote.

export const MAX_VOICE_BYTES = 256 * 1024;
export const MAX_VOICE_MS = 20_500; // 20 s recorder cap + encoder slack
// F5 (2026-09-26): at least 1 s, so every note falls in a replay band.
export const MIN_VOICE_MS = 1_000;
export const ORPHAN_TTL_MS = 24 * 60 * 60 * 1000; // upload never became a plan
export const RETAIN_AFTER_DUE_MS = 7 * 24 * 60 * 60 * 1000;

const ITEM_ID = /^[A-Za-z0-9]{10,40}$/;
const UID = /^[A-Za-z0-9_-]{1,128}$/;
const M4A_BRANDS = new Set(['M4A ', 'mp42', 'isom', 'mp41', 'iso5', 'iso6', 'MSNV']);

export function objectKey(targetUid, itemId) {
  return `items/${targetUid}/${itemId}.m4a`;
}

function u32(bytes, at) {
  return ((bytes[at] << 24) >>> 0) + (bytes[at + 1] << 16) + (bytes[at + 2] << 8) + bytes[at + 3];
}

function fourcc(bytes, at) {
  return String.fromCharCode(bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]);
}

/** True only for an MPEG-4 audio container (`ftyp` box with an M4A brand). */
export function sniffM4a(bytes) {
  if (!bytes || bytes.length < 12) return false;
  if (fourcc(bytes, 4) !== 'ftyp') return false;
  return M4A_BRANDS.has(fourcc(bytes, 8));
}

/** Walk sibling boxes in [start, end); returns `{ type, start, end }[]`. */
function boxes(bytes, start, end) {
  const out = [];
  let at = start;
  while (at + 8 <= end) {
    let size = u32(bytes, at);
    const type = fourcc(bytes, at + 4);
    let header = 8;
    if (size === 1) {
      if (at + 16 > end) break;
      const high = u32(bytes, at + 8);
      if (high !== 0) break; // > 4 GB: not a voice note
      size = u32(bytes, at + 12);
      header = 16;
    } else if (size === 0) {
      size = end - at;
    }
    if (size < header || at + size > end) break;
    out.push({ type, start: at + header, end: at + size });
    at += size;
  }
  return out;
}

/**
 * Duration from the container's own `moov/mvhd` header, in ms — never from
 * the phone. Null when the file has no readable header.
 */
export function mp4DurationMs(bytes) {
  const moov = boxes(bytes, 0, bytes.length).find((b) => b.type === 'moov');
  if (!moov) return null;
  const mvhd = boxes(bytes, moov.start, moov.end).find((b) => b.type === 'mvhd');
  if (!mvhd) return null;
  const version = bytes[mvhd.start];
  let timescale;
  let duration;
  if (version === 0) {
    if (mvhd.start + 20 > mvhd.end) return null;
    timescale = u32(bytes, mvhd.start + 12);
    duration = u32(bytes, mvhd.start + 16);
  } else if (version === 1) {
    if (mvhd.start + 32 > mvhd.end) return null;
    timescale = u32(bytes, mvhd.start + 20);
    const high = u32(bytes, mvhd.start + 24);
    if (high !== 0) return null;
    duration = u32(bytes, mvhd.start + 28);
  } else {
    return null;
  }
  if (!timescale) return null;
  return Math.round((duration * 1000) / timescale);
}

export async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * May [plannerUid] plan for [targetUid] right now? The item does not exist
 * yet, so this mirrors the create rule: a group grant for the stated group,
 * or (while friends) the friendship planning OR emergency grant.
 */
export async function callerMayPlanFor(db, plannerUid, targetUid, groupId) {
  const grantId = `${plannerUid}_${targetUid}`;
  if (groupId) {
    const g = await db.getDoc(`groups/${groupId}/plannerGrants/${grantId}`);
    if (g && g.granted === true) return true;
  }
  const pair = [plannerUid, targetUid].sort().join('_');
  if (!(await db.getDoc(`friendships/${pair}`))) return false;
  for (const sub of ['plannerGrants', 'emergencyGrants']) {
    const g = await db.getDoc(`friendships/${pair}/${sub}/${grantId}`);
    if (g && g.granted === true) return true;
  }
  return false;
}

const reply = (status, body) => ({ status, body });

/**
 * Upload policy. `ctx = { db, storage, now }`; `storage.put(key, bytes)`.
 * Returns `{ status, body }`.
 */
export async function voiceUpload(ctx, { callerUid, targetUid, itemId, groupId, bytes }) {
  if (!UID.test(targetUid || '') || !ITEM_ID.test(itemId || '')
      || (groupId && !ITEM_ID.test(groupId))) {
    return reply(400, { error: 'invalid-request' });
  }
  if (callerUid === targetUid) {
    // Voice notes are for someone else's alarm; self-plans ring the tone.
    return reply(403, { error: 'self-plan' });
  }
  if (!bytes || bytes.length === 0) return reply(400, { error: 'empty' });
  if (bytes.length > MAX_VOICE_BYTES) return reply(413, { error: 'too-large' });
  if (!sniffM4a(bytes)) return reply(415, { error: 'unsupported-type' });
  const durationMs = mp4DurationMs(bytes);
  if (durationMs === null) return reply(415, { error: 'unreadable-audio' });
  if (durationMs > MAX_VOICE_MS) return reply(413, { error: 'too-long' });
  if (durationMs < MIN_VOICE_MS) return reply(400, { error: 'too-short' });

  if (!(await callerMayPlanFor(ctx.db, callerUid, targetUid, groupId))) {
    return reply(403, { error: 'no-planning-permission' });
  }
  // Immutable once the plan exists: the recipient's copy must match forever.
  if (await ctx.db.getDoc(`scheduleItems/${targetUid}/items/${itemId}`)) {
    return reply(409, { error: 'item-exists' });
  }
  const recordPath = `voiceUploads/${itemId}`;
  const existing = await ctx.db.getDoc(recordPath);
  if (existing && (existing.uploaderUid !== callerUid || existing.targetUid !== targetUid)) {
    return reply(403, { error: 'not-yours' });
  }

  const sha256 = await sha256Hex(bytes);
  const stored = await ctx.storage.put(objectKey(targetUid, itemId), bytes);
  if (!stored) return reply(502, { error: 'store-failed' });

  const now = ctx.now || new Date();
  await ctx.db.patchDoc(recordPath, {
    uploaderUid: callerUid,
    targetUid,
    sha256,
    durationMs,
    sizeBytes: bytes.length,
    createdAt: now,
    // Orphan deadline; the sweep extends it once the plan exists.
    expiresAt: new Date(now.getTime() + ORPHAN_TTL_MS),
    // A fresh recording (even one replacing an attached library note) is
    // saved to the library once its plan is sent (32d).
    librarySavedAt: null,
  });
  return reply(200, { sha256, durationMs, sizeBytes: bytes.length });
}

/** Download policy. Returns `{ status, body }` or `{ status, bytes, sha256 }`. */
export async function voiceDownload(ctx, { callerUid, targetUid, itemId }) {
  if (!UID.test(targetUid || '') || !ITEM_ID.test(itemId || '')) {
    return reply(400, { error: 'invalid-request' });
  }
  const item = await ctx.db.getDoc(`scheduleItems/${targetUid}/items/${itemId}`);
  if (!item || item.targetUid !== targetUid) return reply(404, { error: 'not-found' });
  if (callerUid !== targetUid && callerUid !== item.createdByUid) {
    return reply(403, { error: 'forbidden' });
  }
  const note = item.voiceNote;
  if (!note || typeof note.sha256 !== 'string') return reply(404, { error: 'no-voice-note' });
  const bytes = await ctx.storage.get(objectKey(targetUid, itemId));
  if (!bytes) return reply(410, { error: 'gone' });
  const sha256 = await sha256Hex(bytes);
  // Never hand out bytes that are not the ones the plan was approved with.
  if (sha256 !== note.sha256) return reply(409, { error: 'integrity-mismatch' });
  return { status: 200, bytes, sha256 };
}

/**
 * Cleanup (cron). `ctx.db.listDueVoiceUploads(now, limit)` returns
 * `{ id, data }` for `voiceUploads` whose `expiresAt` has passed. An upload
 * that never became a plan (or became a plan without it) is deleted; a used
 * one lives until 7 days after its plan's scheduled time.
 */
export async function sweepVoiceUploads(ctx, now = new Date(), limit = 15) {
  const summary = { considered: 0, deleted: 0, extended: 0 };
  const due = await ctx.db.listDueVoiceUploads(now, limit);
  summary.considered = due.length;
  for (const row of due) {
    const record = row.data || {};
    const itemId = row.id;
    const targetUid = record.targetUid;
    if (!UID.test(targetUid || '') || !ITEM_ID.test(itemId || '')) continue;
    const item = await ctx.db.getDoc(`scheduleItems/${targetUid}/items/${itemId}`);
    const used = item && item.voiceNote && item.voiceNote.sha256 === record.sha256;
    if (used && ctx.saveToLibrary) {
      // Fallback for the library save (32d) should the send-time one have
      // failed; idempotent, and never allowed to stall the sweep.
      try {
        await ctx.saveToLibrary({ targetUid, itemId, item }, now);
      } catch (e) {
        console.error('voice library save (sweep) failed', { name: e?.name || 'Error' });
      }
    }
    if (used) {
      const keepUntil = Date.parse(item.scheduledInstantUtc) + RETAIN_AFTER_DUE_MS;
      if (Number.isFinite(keepUntil) && keepUntil > now.getTime()) {
        await ctx.db.patchDoc(`voiceUploads/${itemId}`, { expiresAt: new Date(keepUntil) });
        summary.extended += 1;
        continue;
      }
    }
    // The record is only dropped once the audio is really gone, so a failed
    // delete is retried by the next sweep instead of orphaned forever.
    if (!(await ctx.storage.delete(objectKey(targetUid, itemId)))) continue;
    await ctx.db.deleteDoc(`voiceUploads/${itemId}`);
    summary.deleted += 1;
  }
  return summary;
}

/** Supabase-backed `storage` for the private bucket. */
export function makeVoiceStorage(env) {
  const base = `${String(env.SUPABASE_URL || '').replace(/\/$/, '')}/storage/v1/object/${env.SUPABASE_VOICE_BUCKET}`;
  const headers = (extra = {}) => ({
    apikey: env.SUPABASE_SERVICE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
    ...extra,
  });
  return {
    configured: Boolean(env.SUPABASE_URL && env.SUPABASE_VOICE_BUCKET && env.SUPABASE_SERVICE_KEY),
    async put(key, bytes) {
      const res = await fetch(`${base}/${key}`, {
        method: 'POST',
        headers: headers({ 'Content-Type': 'audio/mp4', 'x-upsert': 'true' }),
        body: bytes,
      });
      if (!res.ok) console.error('voice storage put failed', { status: res.status });
      return res.ok;
    },
    async get(key) {
      const res = await fetch(`${base}/${key}`, { headers: headers() });
      if (res.status === 404 || res.status === 400) return null;
      if (!res.ok) throw new Error(`voice storage get → ${res.status}`);
      return new Uint8Array(await res.arrayBuffer());
    },
    /** True when the object is gone (deleted now, or already absent). */
    async delete(key) {
      try {
        const res = await fetch(`${base}/${key}`, { method: 'DELETE', headers: headers() });
        if (res.ok || res.status === 404 || res.status === 400) return true;
        console.error('voice storage delete failed', { status: res.status });
        return false;
      } catch {
        return false;
      }
    },
  };
}
