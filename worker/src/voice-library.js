// Voice-note library (item 32d, 2026-09-26).
//
// Every voice note a planner SENDS is kept in their private library
// (user-directed: automatic, no Save button), capped at 20 — the 21st pushes
// the oldest out (first in, first out). Audio sits in the same private bucket
// at `library/{uid}/{noteId}.m4a`; the listing is
// `users/{uid}/voiceLibrary/{noteId}` {sha256, durationMs, sizeBytes,
// createdAt, [name]}. Only this Worker creates or deletes entries (so a
// document never outlives, or lacks, its audio); the owner may rename.
//
//   GET    /voice/library/{noteId}   play (owner only)
//   DELETE /voice/library/{noteId}   delete audio, then the entry (owner only)
//   POST   /voice/attach             reuse a library note on a new plan:
//          headers x-note-id, x-target-uid, x-item-id, [x-group-id]
//
// Attaching copies the audio server-side to the plan's own object and writes
// the same `voiceUploads/{itemId}` record a fresh upload does, so the item
// create rule (`voiceNoteIsValidOnCreate`) is unchanged.

import {
  ORPHAN_TTL_MS,
  callerMayPlanFor,
  objectKey,
  sha256Hex,
} from './voice.js';

export const LIBRARY_LIMIT = 20;

const NOTE_ID = /^[A-Za-z0-9]{10,40}$/;
const UID = /^[A-Za-z0-9_-]{1,128}$/;
const SHA = /^[0-9a-f]{64}$/;

export function libraryKey(ownerUid, noteId) {
  return `library/${ownerUid}/${noteId}.m4a`;
}

const libraryPath = (ownerUid) => `users/${ownerUid}/voiceLibrary`;
const reply = (status, body) => ({ status, body });
const time = (v) => (v instanceof Date ? v.getTime() : Date.parse(v) || 0);

/**
 * Keep the newest [LIBRARY_LIMIT]; delete the rest oldest-first. The entry is
 * only dropped once its audio is gone, so a failed delete is retried on the
 * next save instead of leaving an entry with no sound.
 */
async function evictOverflow(ctx, ownerUid, entries) {
  const oldestFirst = [...entries].sort((a, b) => time(a.data.createdAt) - time(b.data.createdAt));
  let evicted = 0;
  while (oldestFirst.length - evicted > LIBRARY_LIMIT) {
    const victim = oldestFirst[evicted];
    evicted += 1;
    if (!(await ctx.storage.delete(libraryKey(ownerUid, victim.id)))) continue;
    await ctx.db.deleteDoc(`${libraryPath(ownerUid)}/${victim.id}`);
  }
  return evicted;
}

/**
 * Save the voice note of a SENT plan into its planner's library. Idempotent:
 * `voiceUploads/{itemId}.librarySavedAt` marks it done (so a note the owner
 * later deletes is never re-added), and a note already in the library (the
 * same audio, e.g. attached from it) is not duplicated.
 */
export async function saveSentVoiceNote(ctx, { targetUid, itemId, item }, now = new Date()) {
  const ownerUid = item && item.createdByUid;
  const note = item && item.voiceNote;
  if (!UID.test(ownerUid || '') || ownerUid === targetUid || !NOTE_ID.test(itemId || '')) {
    return 'not-applicable';
  }
  if (!note || !SHA.test(note.sha256 || '')) return 'no-voice-note';
  const uploadPath = `voiceUploads/${itemId}`;
  const upload = await ctx.db.getDoc(uploadPath);
  if (!upload || upload.uploaderUid !== ownerUid || upload.sha256 !== note.sha256) {
    return 'no-upload';
  }
  if (upload.librarySavedAt) return 'already-saved';

  const entries = await ctx.db.listDocs(libraryPath(ownerUid));
  if (entries.some((e) => e.data && e.data.sha256 === note.sha256)) {
    await ctx.db.patchDoc(uploadPath, { librarySavedAt: now });
    return 'duplicate';
  }
  const bytes = await ctx.storage.get(objectKey(targetUid, itemId));
  if (!bytes || (await sha256Hex(bytes)) !== note.sha256) return 'audio-missing';
  if (!(await ctx.storage.put(libraryKey(ownerUid, itemId), bytes))) return 'store-failed';
  const entry = {
    sha256: note.sha256,
    durationMs: upload.durationMs,
    sizeBytes: bytes.length,
    createdAt: now,
  };
  await ctx.db.patchDoc(`${libraryPath(ownerUid)}/${itemId}`, entry);
  await ctx.db.patchDoc(uploadPath, { librarySavedAt: now });
  await evictOverflow(ctx, ownerUid, [...entries, { id: itemId, data: entry }]);
  return 'saved';
}

async function ownEntry(ctx, callerUid, noteId) {
  if (!UID.test(callerUid || '') || !NOTE_ID.test(noteId || '')) return null;
  return ctx.db.getDoc(`${libraryPath(callerUid)}/${noteId}`);
}

/** Play one of your own notes. `{status, bytes, sha256}` or `{status, body}`. */
export async function libraryDownload(ctx, { callerUid, noteId }) {
  if (!NOTE_ID.test(noteId || '')) return reply(400, { error: 'invalid-request' });
  const entry = await ownEntry(ctx, callerUid, noteId);
  if (!entry) return reply(404, { error: 'not-found' });
  const bytes = await ctx.storage.get(libraryKey(callerUid, noteId));
  if (!bytes) return reply(410, { error: 'gone' });
  const sha256 = await sha256Hex(bytes);
  if (sha256 !== entry.sha256) return reply(409, { error: 'integrity-mismatch' });
  return { status: 200, bytes, sha256 };
}

/** Delete one of your own notes: audio first, then the entry. */
export async function libraryDelete(ctx, { callerUid, noteId }) {
  if (!NOTE_ID.test(noteId || '')) return reply(400, { error: 'invalid-request' });
  const entry = await ownEntry(ctx, callerUid, noteId);
  if (!entry) return reply(200, { deleted: false }); // already gone
  if (!(await ctx.storage.delete(libraryKey(callerUid, noteId)))) {
    return reply(502, { error: 'store-failed' });
  }
  await ctx.db.deleteDoc(`${libraryPath(callerUid)}/${noteId}`);
  return reply(200, { deleted: true });
}

/**
 * Attach one of your library notes to a plan about to be created. Same checks
 * as a fresh upload (permission, immutability, ownership of the record), then
 * a server-side copy.
 */
export async function libraryAttach(ctx, { callerUid, noteId, targetUid, itemId, groupId }) {
  if (!NOTE_ID.test(noteId || '') || !UID.test(targetUid || '') || !NOTE_ID.test(itemId || '')
      || (groupId && !NOTE_ID.test(groupId))) {
    return reply(400, { error: 'invalid-request' });
  }
  if (callerUid === targetUid) return reply(403, { error: 'self-plan' });
  const entry = await ownEntry(ctx, callerUid, noteId);
  if (!entry) return reply(404, { error: 'not-found' });
  if (!(await callerMayPlanFor(ctx.db, callerUid, targetUid, groupId))) {
    return reply(403, { error: 'no-planning-permission' });
  }
  if (await ctx.db.getDoc(`scheduleItems/${targetUid}/items/${itemId}`)) {
    return reply(409, { error: 'item-exists' });
  }
  const recordPath = `voiceUploads/${itemId}`;
  const existing = await ctx.db.getDoc(recordPath);
  if (existing && (existing.uploaderUid !== callerUid || existing.targetUid !== targetUid)) {
    return reply(403, { error: 'not-yours' });
  }
  const bytes = await ctx.storage.get(libraryKey(callerUid, noteId));
  if (!bytes) return reply(410, { error: 'gone' });
  const sha256 = await sha256Hex(bytes);
  if (sha256 !== entry.sha256) return reply(409, { error: 'integrity-mismatch' });
  if (!(await ctx.storage.put(objectKey(targetUid, itemId), bytes))) {
    return reply(502, { error: 'store-failed' });
  }
  const now = ctx.now || new Date();
  await ctx.db.patchDoc(recordPath, {
    uploaderUid: callerUid,
    targetUid,
    sha256,
    durationMs: entry.durationMs,
    sizeBytes: bytes.length,
    createdAt: now,
    expiresAt: new Date(now.getTime() + ORPHAN_TTL_MS),
    // It came FROM the library: never saved back into it.
    librarySavedAt: now,
  });
  return reply(200, { sha256, durationMs: entry.durationMs, sizeBytes: bytes.length });
}
