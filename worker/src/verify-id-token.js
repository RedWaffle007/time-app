// verify-id-token.js — verify a Firebase Auth ID token in the Worker, so the
// push endpoint isn't an open spammer. Uses Google's published JWK set (JWK
// format imports straight into WebCrypto — no X.509 parsing needed).
//
// Checks: RS256 + known kid, valid signature, correct aud/iss for THIS project,
// not expired, issued/auth in the past. Returns the verified uid (sub).

import { base64UrlToBytes, base64UrlToJson } from './util.js';

const JWK_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';

const SKEW_SECONDS = 60;

// Per-isolate cache of the imported public keys, keyed by kid, with an expiry
// taken from the endpoint's Cache-Control max-age.
let jwkCache = null; // { keys: Map<kid, CryptoKey>, expEpochMs }

export class IdTokenError extends Error {}

export async function verifyFirebaseIdToken(token, projectId) {
  if (typeof token !== 'string' || token.split('.').length !== 3) {
    throw new IdTokenError('malformed token');
  }
  const [headerB64, payloadB64, sigB64] = token.split('.');

  let header;
  let payload;
  try {
    header = base64UrlToJson(headerB64);
    payload = base64UrlToJson(payloadB64);
  } catch {
    throw new IdTokenError('undecodable token');
  }

  if (header.alg !== 'RS256' || !header.kid) {
    throw new IdTokenError('unexpected token header');
  }

  const key = await getPublicKey(header.kid);
  if (!key) throw new IdTokenError('unknown signing key');

  const ok = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    base64UrlToBytes(sigB64),
    new TextEncoder().encode(`${headerB64}.${payloadB64}`),
  );
  if (!ok) throw new IdTokenError('bad signature');

  const now = Math.floor(Date.now() / 1000);
  const expectedIss = `https://securetoken.google.com/${projectId}`;
  if (payload.aud !== projectId) throw new IdTokenError('wrong audience');
  if (payload.iss !== expectedIss) throw new IdTokenError('wrong issuer');
  if (typeof payload.exp !== 'number' || payload.exp < now - SKEW_SECONDS) {
    throw new IdTokenError('token expired');
  }
  if (typeof payload.iat !== 'number' || payload.iat > now + SKEW_SECONDS) {
    throw new IdTokenError('token issued in the future');
  }
  if (!payload.sub || typeof payload.sub !== 'string') {
    throw new IdTokenError('missing subject');
  }
  return payload.sub;
}

async function getPublicKey(kid) {
  const now = Date.now();
  if (!jwkCache || jwkCache.expEpochMs < now) {
    const resp = await fetch(JWK_URL);
    if (!resp.ok) throw new IdTokenError('could not fetch signing keys');
    const { keys } = await resp.json();
    const imported = new Map();
    for (const jwk of keys) {
      const cryptoKey = await crypto.subtle.importKey(
        'jwk',
        jwk,
        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
        false,
        ['verify'],
      );
      imported.set(jwk.kid, cryptoKey);
    }
    jwkCache = { keys: imported, expEpochMs: now + maxAgeMs(resp) };
  }
  return jwkCache.keys.get(kid);
}

function maxAgeMs(resp) {
  const cc = resp.headers.get('cache-control') || '';
  const m = cc.match(/max-age=(\d+)/);
  return m ? parseInt(m[1], 10) * 1000 : 3600_000;
}
