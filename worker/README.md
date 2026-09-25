# time-app-notify (Cloudflare Worker)

Authenticated app-event push, profile/group picture storage, plus the scheduled
six-hour inactivity notifier.
The Flutter app POSTs relationship/item events here; this Worker verifies the
caller, resolves the entitled recipient, and sends the FCM push. A five-minute
cron separately queries private per-user inactivity state and sends due prompts.

**Why a Worker and not a Cloud Function:** no payment card yet, so no Firebase
Blaze. This is the no-card transport. All notification *policy* lives in
`src/notify.js` so moving to a Firestore-triggered Cloud Function later is a
transport swap, not a rewrite. See `DECISIONS.md` → "Completion→planner push".

## Layout

| File | Role |
| --- | --- |
| `src/notify.js` | **Portable policy** — recipient resolution, payload, dedup guard, server-side outcome verify, token cleanup. Reused verbatim by a future Cloud Function. |
| `src/inactivity.js` | **Portable scheduled policy** — 50-message cursor, due-time validation, lease/dedup, delivery, and token cleanup. |
| `src/avatar.js` | Byte-sniffed profile/group picture upload and scoped deletion through Supabase Storage. |
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

# Privileged Supabase Storage credential used only by the avatar routes:
wrangler secret put SUPABASE_SERVICE_KEY

wrangler deploy      # prints the endpoint URL
```

Deployment also installs the `*/5 * * * *` cron declared in `wrangler.toml`.
The app/rules and Worker therefore need to be deployed together when enabling
inactivity notifications; a Git push by itself changes neither backend.

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
- Item body: `{ "event": "created" | "decided" | "outcome" | "withdrawn", "targetUid": "...", "itemId": "..." }`
- Relationship body: `{ "event": "friendRequest" | "friendAccept" | "planningRequest" | "planningApprove", "fromUid": "...", "toUid": "...", "kind": "normal" | "emergency"? }`
- Plan-request body: `{ "event": "planRequested", "fromUid": "...", "toUid": "...", "planRequestId": "..." }`

Returns `200` with `{ sent, cleaned, recipientUid, reason }` on any handled
outcome (including "nothing to send" reasons like `already-notified` /
`no-active-grant` — do **not** retry those). `401` unauthenticated, `403` if the
caller isn't the item's target, `4xx` malformed, `500` on backend error (nothing
is sent on error).

`POST|DELETE /avatar`
- Requires a verified Firebase ID token.
- Stores/deletes only under `avatars/{verifiedUid}/`.

`POST|DELETE /group-avatar`
- Requires the token plus `X-Group-Id`.
- Re-reads `groups/{groupId}` and proceeds only when the verified caller is the
  owner.
- Stores/deletes only under `group-avatars/{groupId}/`.

Both upload routes accept byte-sniffed JPEG, PNG, GIF, or WebP with the shared
2 MB static / 5 MB animated-capable limits. The bucket must be public for image
display; all writes still go through the Worker-held service-role credential.
