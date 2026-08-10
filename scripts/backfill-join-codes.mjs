#!/usr/bin/env node
// backfill-join-codes.mjs — one-off migration: write joinCodes/{CODE} = {groupId}
// for every group that already exists.
//
// WHY THIS EXISTS
//   `groups` used to be readable by any signed-in user, which is how join-by-code
//   resolved a code: `where('joinCode', '==', CODE)`. That also let anyone list
//   every group and every invite code, so the read is now members-only and the
//   lookup moved to its own `joinCodes/{CODE}` collection (see firestore.rules).
//   Groups created BEFORE that change have no lookup doc, so nobody can join them
//   any more. This backfills them.
//
// WHY IT RUNS AS THE SERVICE ACCOUNT
//   Not as a convenience — it is the only identity that can do this at all:
//     • Under the OLD rules there is no `joinCodes` match, so it falls through to
//       deny: no signed-in user can write these docs.
//     • Under the NEW rules a user may write a code only for a group they OWN,
//       and may not list `groups` at all — so no user can enumerate what to write.
//   A service-account token bypasses security rules entirely, on both the read and
//   the write. That also means THIS SCRIPT IS RULES-INDEPENDENT: it does not
//   matter whether it runs before or after the rules are deployed.
//
// SAFETY
//   • Dry run by default. Pass --apply to actually write.
//   • Only ever CREATES `joinCodes` docs. Never writes, alters or deletes a group.
//   • Idempotent: a code already pointing at the right group is skipped, so
//     re-running is a no-op. Re-running after the new client ships is expected —
//     it catches groups made by an old client during the rollout window.
//   • Never overwrites a code that points somewhere else. That is reported as a
//     COLLISION and skipped: the rules make these docs immutable on purpose, and
//     silently repointing a code is exactly how a joiner lands in the wrong group.
//   • Writes carry `currentDocument.exists=false`, so a concurrent writer loses
//     the race instead of being clobbered.
//
// USAGE
//   node scripts/backfill-join-codes.mjs [--apply] [--project ID]
//                                        [--key sa.json | --token ACCESS_TOKEN]
//
//   Credentials, first match wins:
//     --token <t>  / $GOOGLE_ACCESS_TOKEN          e.g. gcloud auth print-access-token
//     --key <path> / $GOOGLE_APPLICATION_CREDENTIALS   service-account JSON
//
//   The service-account JSON is the same credential the push Worker uses (stored
//   there as the `FIREBASE_SERVICE_ACCOUNT` wrangler secret). It is deliberately
//   not in this repo — pass a local copy and delete it afterwards.
//
// No dependencies: `fetch` and `crypto.subtle` are Node globals. Nothing to install.

import { readFileSync } from 'node:fs';

const OAUTH_TOKEN_URI = 'https://oauth2.googleapis.com/token';
const SCOPE = 'https://www.googleapis.com/auth/datastore';
const PAGE_SIZE = 300;

// --- args -----------------------------------------------------------------

function parseArgs(argv) {
  const args = { apply: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--apply') args.apply = true;
    else if (a === '--help' || a === '-h') args.help = true;
    else if (a === '--key') args.key = argv[++i];
    else if (a === '--token') args.token = argv[++i];
    else if (a === '--project') args.project = argv[++i];
    else throw new Error(`unknown argument: ${a}`);
  }
  return args;
}

const USAGE = `
backfill-join-codes — write joinCodes/{CODE} = {groupId} for existing groups.

  node scripts/backfill-join-codes.mjs [--apply] [--project ID]
                                       [--key sa.json | --token ACCESS_TOKEN]

  --apply            perform the writes (default is a dry run)
  --key <path>       service-account JSON  (or $GOOGLE_APPLICATION_CREDENTIALS)
  --token <t>        OAuth access token    (or $GOOGLE_ACCESS_TOKEN)
  --project <id>     project id (defaults to the key's project_id)

Creates only. Never modifies a group. Safe to re-run.
`.trim();

// --- auth -----------------------------------------------------------------

const b64url = (bytes) =>
  Buffer.from(bytes).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const jsonToB64url = (obj) => b64url(new TextEncoder().encode(JSON.stringify(obj)));

/** PEM (PKCS#8) → raw DER bytes. */
function pemToBytes(pem) {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, '')
    .replace(/-----END [^-]+-----/, '')
    .replace(/\s+/g, '');
  return Buffer.from(body, 'base64');
}

/**
 * Sign a service-account JWT and exchange it for an OAuth access token. Same
 * flow as worker/src/google-auth.js — inlined rather than imported because
 * `worker/` has no package.json, so Node resolves its .js files as CommonJS and
 * the import would fail. Not worth adding a package.json to a deployed Worker.
 */
async function getAccessToken(serviceAccount) {
  const iat = Math.floor(Date.now() / 1000);
  const claims = {
    iss: serviceAccount.client_email,
    scope: SCOPE,
    aud: OAUTH_TOKEN_URI,
    iat,
    exp: iat + 3600,
  };
  const signingInput =
    `${jsonToB64url({ alg: 'RS256', typ: 'JWT' })}.${jsonToB64url(claims)}`;

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToBytes(serviceAccount.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(signingInput),
  );
  const assertion = `${signingInput}.${b64url(new Uint8Array(sig))}`;

  const resp = await fetch(OAUTH_TOKEN_URI, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!resp.ok) {
    throw new Error(`OAuth token exchange failed (${resp.status}): ${await resp.text()}`);
  }
  return (await resp.json()).access_token;
}

/** Resolve credentials + project id from flags and environment. */
async function resolveAuth(args) {
  // Standard emulator escape hatch, so this script can be exercised for real
  // without production credentials. The emulator ignores the bearer token.
  if (process.env.FIRESTORE_EMULATOR_HOST) {
    const projectId = args.project || 'demo-time-app';
    return { token: 'owner', projectId };
  }

  const token = args.token || process.env.GOOGLE_ACCESS_TOKEN;
  if (token) {
    if (!args.project) {
      throw new Error('--project is required when authenticating with --token');
    }
    return { token, projectId: args.project };
  }

  const keyPath = args.key || process.env.GOOGLE_APPLICATION_CREDENTIALS;
  if (!keyPath) {
    throw new Error(
      'no credentials: pass --key <service-account.json> or --token <access-token>',
    );
  }
  const serviceAccount = JSON.parse(readFileSync(keyPath, 'utf8'));
  const projectId = args.project || serviceAccount.project_id;
  if (!projectId) {
    throw new Error('could not determine the project id; pass --project');
  }
  return { token: await getAccessToken(serviceAccount), projectId };
}

// --- Firestore REST -------------------------------------------------------

function makeDb(projectId, token) {
  const emulator = process.env.FIRESTORE_EMULATOR_HOST;
  const origin = emulator
    ? `http://${emulator}`
    : 'https://firestore.googleapis.com';
  const base =
    `${origin}/v1/projects/${projectId}/databases/(default)/documents`;
  const auth = { Authorization: `Bearer ${token}` };

  return {
    /** Every doc in a collection, following pagination. */
    async listAll(collection) {
      const out = [];
      let pageToken;
      do {
        const url = new URL(`${base}/${collection}`);
        url.searchParams.set('pageSize', String(PAGE_SIZE));
        if (pageToken) url.searchParams.set('pageToken', pageToken);

        const resp = await fetch(url, { headers: auth });
        if (resp.status === 404) return out;
        if (!resp.ok) {
          throw new Error(`list ${collection} → ${resp.status}: ${await resp.text()}`);
        }
        const json = await resp.json();
        out.push(...(json.documents || []));
        pageToken = json.nextPageToken;
      } while (pageToken);
      return out;
    },

    async getDoc(path) {
      const resp = await fetch(`${base}/${encodePath(path)}`, { headers: auth });
      if (resp.status === 404) return null;
      if (!resp.ok) {
        throw new Error(`get ${path} → ${resp.status}: ${await resp.text()}`);
      }
      return resp.json();
    },

    /** Create-only: fails if the document already exists. */
    async createDoc(path, fields) {
      const url = new URL(`${base}/${encodePath(path)}`);
      for (const k of Object.keys(fields)) {
        url.searchParams.append('updateMask.fieldPaths', k);
      }
      url.searchParams.set('currentDocument.exists', 'false');

      const resp = await fetch(url, {
        method: 'PATCH',
        headers: { ...auth, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          fields: Object.fromEntries(
            Object.entries(fields).map(([k, v]) => [k, { stringValue: v }]),
          ),
        }),
      });
      if (!resp.ok) {
        throw new Error(`create ${path} → ${resp.status}: ${await resp.text()}`);
      }
    },
  };
}

const encodePath = (path) => path.split('/').map(encodeURIComponent).join('/');
const docId = (doc) => doc.name.split('/').pop();
const str = (doc, field) => doc.fields?.[field]?.stringValue ?? '';

// --- the backfill ---------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(USAGE);
    return;
  }

  const { token, projectId } = await resolveAuth(args);
  const db = makeDb(projectId, token);

  console.log(`project : ${projectId}`);
  console.log(`mode    : ${args.apply ? 'APPLY (writing)' : 'DRY RUN (no writes)'}`);
  console.log('');

  const groups = await db.listAll('groups');
  console.log(`scanning ${groups.length} group(s)\n`);

  const counts = { created: 0, alreadyCorrect: 0, collisions: 0, noCode: 0 };
  // Codes seen in THIS run, so two groups sharing one code is caught even when
  // neither has been written yet.
  const seen = new Map(); // code → groupId

  for (const group of groups) {
    const groupId = docId(group);
    const name = str(group, 'name') || '(unnamed)';
    const code = str(group, 'joinCode').trim().toUpperCase();

    if (!code) {
      counts.noCode += 1;
      console.log(`  SKIP      ${groupId}  "${name}" — has no joinCode`);
      continue;
    }

    const duplicate = seen.get(code);
    if (duplicate && duplicate !== groupId) {
      counts.collisions += 1;
      console.log(
        `  COLLISION ${code} → groups ${duplicate} AND ${groupId} share this code`,
      );
      continue;
    }
    seen.set(code, groupId);

    const existing = await db.getDoc(`joinCodes/${code}`);
    if (existing) {
      const pointsAt = str(existing, 'groupId');
      if (pointsAt === groupId) {
        counts.alreadyCorrect += 1;
        console.log(`  OK        ${code} → ${groupId}  "${name}"`);
      } else {
        counts.collisions += 1;
        console.log(
          `  COLLISION ${code} already points at ${pointsAt}, not ${groupId} ` +
            `("${name}") — left alone`,
        );
      }
      continue;
    }

    counts.created += 1;
    if (args.apply) {
      await db.createDoc(`joinCodes/${code}`, { groupId });
      console.log(`  CREATED   ${code} → ${groupId}  "${name}"`);
    } else {
      console.log(`  WOULD ADD ${code} → ${groupId}  "${name}"`);
    }
  }

  console.log('');
  console.log(
    `scanned ${groups.length} · ` +
      `${args.apply ? 'created' : 'to create'} ${counts.created} · ` +
      `already correct ${counts.alreadyCorrect} · ` +
      `collisions ${counts.collisions} · ` +
      `no code ${counts.noCode}`,
  );

  if (counts.collisions > 0) {
    console.log('');
    console.log(
      'COLLISIONS FOUND. Nothing was overwritten. Give the affected group(s) a ' +
        'new joinCode by hand, then re-run.',
    );
    process.exitCode = 1;
    return;
  }

  if (!args.apply && counts.created > 0) {
    console.log('\nDry run — re-run with --apply to write these.');
  }
}

main().catch((e) => {
  console.error(`\nfailed: ${e.message}`);
  process.exitCode = 1;
});
