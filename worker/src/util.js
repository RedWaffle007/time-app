// Small encoding helpers shared by the auth + verify code. Worker runtime only
// (uses atob/btoa + Web APIs), no dependencies.

export function bytesToBase64Url(bytes) {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function base64UrlToBytes(b64url) {
  const b64 = b64url.replace(/-/g, '+').replace(/_/g, '/').padEnd(
    Math.ceil(b64url.length / 4) * 4,
    '=',
  );
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function jsonToBase64Url(obj) {
  return bytesToBase64Url(new TextEncoder().encode(JSON.stringify(obj)));
}

export function base64UrlToJson(b64url) {
  return JSON.parse(new TextDecoder().decode(base64UrlToBytes(b64url)));
}

// Decode a PEM ("-----BEGIN X-----\n<base64>\n-----END X-----") body to bytes.
export function pemToBytes(pem) {
  const b64 = pem
    .replace(/-----BEGIN [^-]+-----/, '')
    .replace(/-----END [^-]+-----/, '')
    .replace(/\s+/g, '');
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
