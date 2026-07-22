// google-auth.js — mint a short-lived Google OAuth2 access token from the
// service-account credential, entirely in the Worker (WebCrypto RS256). The
// private key lives ONLY in the encrypted `FIREBASE_SERVICE_ACCOUNT` secret; it
// never touches the app or the repo.
//
// Scopes: datastore (Firestore REST) + firebase.messaging (FCM v1 send).

import { jsonToBase64Url, bytesToBase64Url, pemToBytes } from './util.js';

const SCOPES = [
  'https://www.googleapis.com/auth/datastore',
  'https://www.googleapis.com/auth/firebase.messaging',
].join(' ');

const TOKEN_URI = 'https://oauth2.googleapis.com/token';

// Per-isolate cache. Workers reuse isolates across requests, so we avoid
// re-signing on every call. Refresh a minute before expiry.
let cached = null; // { token, expEpochMs }

export async function getAccessToken(serviceAccount) {
  const now = Date.now();
  if (cached && cached.expEpochMs - 60_000 > now) return cached.token;

  const iat = Math.floor(now / 1000);
  const exp = iat + 3600;
  const claims = {
    iss: serviceAccount.client_email,
    scope: SCOPES,
    aud: TOKEN_URI,
    iat,
    exp,
  };
  const header = { alg: 'RS256', typ: 'JWT' };
  const signingInput = `${jsonToBase64Url(header)}.${jsonToBase64Url(claims)}`;

  const key = await importPrivateKey(serviceAccount.private_key);
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(signingInput),
  );
  const assertion = `${signingInput}.${bytesToBase64Url(new Uint8Array(sig))}`;

  const body = new URLSearchParams({
    grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
    assertion,
  });
  const resp = await fetch(TOKEN_URI, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`OAuth token exchange failed (${resp.status}): ${text}`);
  }
  const json = await resp.json();
  cached = {
    token: json.access_token,
    expEpochMs: now + (json.expires_in ?? 3600) * 1000,
  };
  return cached.token;
}

async function importPrivateKey(pem) {
  return crypto.subtle.importKey(
    'pkcs8',
    pemToBytes(pem),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}
