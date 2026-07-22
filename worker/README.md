# time-app-notify (Cloudflare Worker)

Client-triggered completion→planner push. The Flutter app POSTs here after the
target writes a done/skip outcome; this Worker verifies the caller, resolves the
entitled planner, and sends the FCM push.

**Why a Worker and not a Cloud Function:** no payment card yet, so no Firebase
Blaze. This is the no-card transport. All notification *policy* lives in
`src/notify.js` so moving to a Firestore-triggered Cloud Function later is a
transport swap, not a rewrite. See `DECISIONS.md` → "Completion→planner push".

## Layout

| File | Role |
| --- | --- |
| `src/notify.js` | **Portable policy** — recipient resolution, payload, dedup guard, server-side outcome verify, token cleanup. Reused verbatim by a future Cloud Function. |
| `src/index.js` | Worker shell — POST-only, body cap, ID-token verify, caller==target authz, fail-closed. |
| `src/verify-id-token.js` | Firebase ID token verification (Google JWK set). |
| `src/google-auth.js` | Service-account → OAuth2 access token (WebCrypto RS256). |
| `src/firestore-rest.js` | `ctx.db` over Firestore REST. |
| `src/fcm-rest.js` | `ctx.fcm` over FCM HTTP v1. |

## Setup

```sh
npm i -g wrangler
cd worker
wrangler login

# Put the WHOLE service-account JSON in one encrypted secret (never in git):
#   Firebase console → Project settings → Service accounts → Generate new private key
wrangler secret put FIREBASE_SERVICE_ACCOUNT
# paste the entire JSON file contents, press enter

wrangler deploy      # prints the endpoint URL
```

Then put the printed URL into the app at `lib/core/config/notify_config.dart`
(`kNotifyEndpoint`). It is not a secret — auth is the ID-token check, not URL
secrecy.

### Local smoke test (optional)

```sh
wrangler dev         # needs the secret in a local .dev.vars (git-ignored)
```

`.dev.vars` example (DO NOT COMMIT — it's git-ignored):

```
FIREBASE_SERVICE_ACCOUNT={"type":"service_account", ... }
```

## Endpoint contract

`POST /`
- Header: `Authorization: Bearer <Firebase ID token>`
- Body: `{ "targetUid": "...", "itemId": "...", "outcome": "done" | "skipped" }`

Returns `200` with `{ sent, cleaned, recipientUid, reason }` on any handled
outcome (including "nothing to send" reasons like `already-notified` /
`no-active-grant` — do **not** retry those). `401` unauthenticated, `403` if the
caller isn't the item's target, `4xx` malformed, `500` on backend error (nothing
is sent on error).
