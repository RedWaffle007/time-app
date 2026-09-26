// Tap-to-open invite links (item 17, 2026-09-26).
//
//   /i/u/{username}  — add a friend by their username
//   /i/g/{joinCode}  — ask to join a group by its code
//
// With Checkmate installed, Android App Links (verified via
// /.well-known/assetlinks.json below) open the app straight on the link; the
// app does the lookup and the request. Without it, the browser shows the small
// page below. The link carries only an existing username or join code — no new
// data, nothing secret: a join code already admits no one without every
// member's approval.

export const APP_PACKAGE = 'com.timeapp.time_app';

// Must match lib/features/social/domain/username.dart (3–20, a–z0–9_, starts
// with a letter) and the group code alphabet (6 of A–Z minus O/I, 2–9).
const USERNAME = /^[a-z][a-z0-9_]{2,19}$/;
const JOIN_CODE = /^[A-HJ-NP-Z2-9]{6}$/;

/** `{ kind, value }` for a well-formed invite path, else null. */
export function parseInvitePath(pathname) {
  const match = /^\/i\/([ug])\/([^/]+)\/?$/.exec(pathname);
  if (!match) return null;
  let value;
  try {
    value = decodeURIComponent(match[2]);
  } catch {
    return null;
  }
  if (match[1] === 'u') {
    value = value.trim().toLowerCase();
    return USERNAME.test(value) ? { kind: 'user', value } : null;
  }
  value = value.trim().toUpperCase();
  return JOIN_CODE.test(value) ? { kind: 'group', value } : null;
}

/**
 * The Digital Asset Links statement Android fetches to verify the app may open
 * these links. Fingerprints come from `APP_CERT_SHA256` (comma-separated, in
 * wrangler.toml) — public values: debug now, release added when it exists.
 */
export function assetLinks(env) {
  const fingerprints = String(env.APP_CERT_SHA256 || '')
    .split(',')
    .map((f) => f.trim().toUpperCase())
    .filter((f) => /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/.test(f));
  return [{
    relation: ['delegate_permission/common.handle_all_urls'],
    target: {
      namespace: 'android_app',
      package_name: APP_PACKAGE,
      sha256_cert_fingerprints: fingerprints,
    },
  }];
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/**
 * The fallback page for someone without the app (or whose browser did not
 * hand the link to it). Values are validated by [parseInvitePath] AND escaped.
 */
export function invitePage(invite, url, env) {
  const host = url.host;
  const path = url.pathname;
  const openIntent =
    `intent://${host}${path}#Intent;scheme=https;package=${APP_PACKAGE};end`;
  const download = String(env.APP_DOWNLOAD_URL || '');
  const heading = invite.kind === 'user'
    ? `@${escapeHtml(invite.value)} invited you to Checkmate`
    : `You're invited to a group on Checkmate`;
  const detail = invite.kind === 'user'
    ? 'Open the link in Checkmate to add them as a friend.'
    : `Open the link in Checkmate to ask to join. Group code: <strong>${escapeHtml(invite.value)}</strong>`;
  const getIt = download
    ? `<a class="secondary" href="${escapeHtml(download)}">Get Checkmate</a>`
    : '<p class="muted">Don’t have Checkmate yet? Ask the person who sent this for the app, then tap the link again.</p>';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Checkmate invite</title>
<style>
  :root { color-scheme: light dark; --bg:#f6f8f5; --fg:#1b1f1b; --muted:#5b645b; --accent:#2f6b3a; --on-accent:#fff; }
  @media (prefers-color-scheme: dark) { :root { --bg:#121512; --fg:#e6ebe5; --muted:#a7b1a6; --accent:#8fd19b; --on-accent:#0d1f11; } }
  body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.5 system-ui, sans-serif; }
  main { max-width:28rem; margin:0 auto; padding:48px 16px; }
  h1 { font-size:1.5rem; line-height:1.3; margin:0 0 12px; }
  p { margin:0 0 24px; }
  .muted { color:var(--muted); font-size:.95rem; }
  a.primary, a.secondary { display:block; text-align:center; padding:14px 16px; border-radius:12px; text-decoration:none; font-weight:600; margin-bottom:12px; }
  a.primary { background:var(--accent); color:var(--on-accent); }
  a.secondary { border:1px solid var(--accent); color:var(--accent); }
</style>
</head>
<body>
<main>
  <h1>${heading}</h1>
  <p>${detail}</p>
  <a class="primary" href="${escapeHtml(openIntent)}">Open in Checkmate</a>
  ${getIt}
</main>
</body>
</html>`;
}

const PAGE_HEADERS = {
  'Content-Type': 'text/html; charset=utf-8',
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Cache-Control': 'public, max-age=300',
};

/** Response for a GET the invite feature owns, or null if it is not one. */
export function handleInviteRequest(request, env) {
  if (request.method !== 'GET' && request.method !== 'HEAD') return null;
  const url = new URL(request.url);
  if (url.pathname === '/.well-known/assetlinks.json') {
    return new Response(JSON.stringify(assetLinks(env)), {
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'public, max-age=3600',
      },
    });
  }
  if (!url.pathname.startsWith('/i/')) return null;
  const invite = parseInvitePath(url.pathname);
  if (!invite) {
    return new Response('Invite link not recognised.', {
      status: 404,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    });
  }
  return new Response(invitePage(invite, url, env), { headers: PAGE_HEADERS });
}
