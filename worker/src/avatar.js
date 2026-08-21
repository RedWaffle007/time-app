// avatar.js — profile-picture upload and deletion.
//
// WHY THIS LIVES IN THE WORKER AT ALL
//
// Firebase Storage needs the Blaze plan and this project deliberately has no
// payment card attached (DECISIONS.md, "Completion→planner push"). The
// replacement is Supabase Storage — Apache-2.0, self-hostable, 1GB free with no
// card, and plain object storage, so an animated GIF or WebP comes back
// byte-for-byte.
//
// But Supabase authorizes with its OWN JWT and has never heard of a Firebase
// uid. Reconciling the two on the phone would mean shipping a Supabase key in
// the APK — extractable in minutes, and it would be a WRITE key. So the phone
// proves who it is with the Firebase ID token it already has, and the storage
// credential stays a Worker secret. That is the same trade this Worker already
// makes for push.
//
// THE SECOND REASON, EQUALLY IMPORTANT: this is where the caps are enforced.
// The client checks size and format too (`avatar.dart`), but only so the user
// hears "too large" before waiting through an upload. A client check is a
// courtesy; this one is the control.
//
// Config (wrangler.toml [vars] + secrets):
//   SUPABASE_URL          e.g. https://xxxx.supabase.co     (var)
//   SUPABASE_BUCKET       e.g. avatars                      (var)
//   SUPABASE_SERVICE_KEY  service_role key                  (SECRET)

// Mirrors kAvatarMimeByExtension in lib/features/social/domain/avatar.dart.
const EXT_BY_MIME = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
};

// Mirrors kAnimatedCapableMimes / the two caps in avatar.dart. Animated formats
// get the larger allowance because frames legitimately cost bytes; one shared
// cap would either ban animation in practice or wave through enormous stills.
const ANIMATED_MIMES = new Set(['image/gif', 'image/webp']);
const MAX_BYTES_STATIC = 2 * 1024 * 1024;
const MAX_BYTES_ANIMATED = 5 * 1024 * 1024;

const maxBytesFor = (mime) =>
  ANIMATED_MIMES.has(mime) ? MAX_BYTES_ANIMATED : MAX_BYTES_STATIC;

/**
 * Identify the format from the BYTES, not from the Content-Type header.
 *
 * A declared MIME is a claim by the caller. Storing a file under a type it does
 * not actually have is how a bucket ends up serving HTML or SVG from an image
 * URL — and an SVG served from a domain a browser trusts is a scripting
 * primitive, not a picture. Sniffing costs 16 bytes and closes it.
 *
 * Returns the real MIME, or null if it is not one of the four we accept.
 */
export function sniffImageMime(bytes) {
  if (bytes.length < 12) return null;
  const b = bytes;

  // JPEG: FF D8 FF
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';

  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (
    b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
    b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a
  ) {
    return 'image/png';
  }

  // GIF: "GIF87a" or "GIF89a". Both are accepted; 89a is the animated one, but
  // the distinction does not change how it is stored or served.
  if (
    b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38 &&
    (b[4] === 0x37 || b[4] === 0x39) && b[5] === 0x61
  ) {
    return 'image/gif';
  }

  // WebP: "RIFF" .... "WEBP". Covers still, lossless and ANIMATED (VP8X with
  // the animation flag) alike — all three share this container header, which
  // is why animated WebP needs no special case anywhere in this pipeline.
  if (
    b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
    b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50
  ) {
    return 'image/webp';
  }

  return null;
}

/**
 * A storage key is only ever this user's if it sits under their own prefix.
 *
 * Every delete is checked against this. Without it, a caller could pass any
 * key in `X-Previous-Key` and have the Worker — which holds a service_role
 * credential and bypasses every storage policy — delete another user's picture
 * on their behalf. The uid comes from the verified token, never from the
 * request body.
 */
export function keyBelongsTo(key, uid) {
  return typeof key === 'string' && key.startsWith(`avatars/${uid}/`);
}

function objectPath(env, key) {
  return `${env.SUPABASE_URL}/storage/v1/object/${env.SUPABASE_BUCKET}/${key}`;
}

function publicUrl(env, key) {
  return `${env.SUPABASE_URL}/storage/v1/object/public/${env.SUPABASE_BUCKET}/${key}`;
}

function storageHeaders(env, extra = {}) {
  return {
    apikey: env.SUPABASE_SERVICE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
    ...extra,
  };
}

function configured(env) {
  return Boolean(
    env.SUPABASE_URL && env.SUPABASE_BUCKET && env.SUPABASE_SERVICE_KEY,
  );
}

/** Best-effort delete. A failure leaves an orphaned object, never a broken user. */
async function deleteObject(env, key) {
  try {
    await fetch(objectPath(env, key), {
      method: 'DELETE',
      headers: storageHeaders(env),
    });
  } catch {
    // Deliberately swallowed — see the note on AvatarUploader.remove. Refusing
    // to replace a picture because the old file would not delete is the wrong
    // way round.
  }
}

/**
 * POST /avatar — body IS the image; Content-Type declares the format.
 *
 * @param {Request} request
 * @param {string} uid  the VERIFIED caller (never taken from the body)
 */
export async function handleAvatarUpload(request, env, uid) {
  if (!configured(env)) {
    return json({ error: 'storage-not-configured' }, 500);
  }

  const declared = (request.headers.get('content-type') || '')
    .split(';')[0]
    .trim()
    .toLowerCase();

  // Cheap rejections first, before reading a single byte of body: an unknown
  // type, or a declared length already over the largest cap. A caller who lies
  // about Content-Length is caught by the real check below.
  if (!EXT_BY_MIME[declared]) return json({ error: 'unsupported-type' }, 415);

  const declaredLength = Number(request.headers.get('content-length') || '0');
  if (declaredLength > MAX_BYTES_ANIMATED) {
    return json({ error: 'too-large' }, 413);
  }

  const buffer = await request.arrayBuffer();
  const bytes = new Uint8Array(buffer);
  if (bytes.length === 0) return json({ error: 'empty' }, 400);

  // THE AUTHORITATIVE FORMAT CHECK. The header said one thing; these are the
  // bytes that actually arrived.
  const mime = sniffImageMime(bytes);
  if (!mime) return json({ error: 'unsupported-type' }, 415);

  // A mismatch between the claim and the reality is refused rather than
  // silently corrected. Storing a GIF that claimed to be a PNG would mean the
  // profile document records a type the file does not have, and every cap
  // decision downstream would be made against the wrong number.
  if (mime !== declared) return json({ error: 'type-mismatch' }, 415);

  // THE AUTHORITATIVE SIZE CHECK, against the bytes received — per format, so
  // an animated file gets its larger allowance and a still does not.
  if (bytes.length > maxBytesFor(mime)) return json({ error: 'too-large' }, 413);

  // Keyed under the uid: it is what makes `keyBelongsTo` a real ownership test.
  // The random suffix means a replacement never reuses a URL a CDN or an
  // Image widget may still be caching, so a new picture appears immediately.
  const key =
    `avatars/${uid}/${Date.now()}-${crypto.randomUUID()}.${EXT_BY_MIME[mime]}`;

  const put = await fetch(objectPath(env, key), {
    method: 'POST',
    headers: storageHeaders(env, {
      'Content-Type': mime,
      // Long cache is safe precisely because the key is unique per upload —
      // the object at a given key never changes.
      'Cache-Control': 'public, max-age=31536000, immutable',
    }),
    body: bytes,
  });

  if (!put.ok) {
    const detail = await put.text().catch(() => '');
    return json({ error: 'store-failed', detail: detail.slice(0, 200) }, 502);
  }

  // Replace AFTER the new object is safely stored. The other order can delete
  // the only copy and then fail to write the replacement.
  const previous = request.headers.get('x-previous-key');
  if (previous && keyBelongsTo(previous, uid) && previous !== key) {
    await deleteObject(env, previous);
  }

  return json(
    {
      url: publicUrl(env, key),
      key,
      mime,
      sizeBytes: bytes.length,
    },
    200,
  );
}

/** DELETE /avatar — `X-Storage-Key` names the object. */
export async function handleAvatarDelete(request, env, uid) {
  if (!configured(env)) {
    return json({ error: 'storage-not-configured' }, 500);
  }
  const key = request.headers.get('x-storage-key');
  // Answer 200 for a key that is not this user's rather than 403. There is
  // nothing to tell them: either it is theirs and it is now gone, or it never
  // was and no state of theirs changed. A 403 here would confirm that some
  // other user's key exists.
  if (!key || !keyBelongsTo(key, uid)) return json({ ok: true }, 200);

  await deleteObject(env, key);
  return json({ ok: true }, 200);
}

function json(obj, status, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...extraHeaders },
  });
}
