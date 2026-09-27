#!/usr/bin/env node
// clear-groups.mjs — one-off reset: delete EVERY group, so everyone starts
// creating groups afresh on the new release build (user-directed 2026-09-27;
// many phones still run builds too old for the current group features).
//
// WHAT IT DELETES (dry run by default; nothing is deleted without --apply)
//   • every groups/{id} document
//   • every subcollection under each group (members, memberStats,
//     joinRequests, the retired plannerGrants, and anything else found via
//     listCollectionIds, so nothing is left orphaned)
//   • every joinCodes/{CODE} lookup (they only ever point at groups)
//   • every groupBusyNotices/{id} dedup row (group-only)
//
// WHAT IT LEAVES ALONE, deliberately
//   • schedule items, including past and upcoming plans made in a group: a
//     person's history stays theirs, and an alarm already armed on a phone
//     still rings. Pushes about such a plan stop (its group no longer exists).
//   • friendships, profiles, stats, voice notes: nothing outside groups.
//   • group pictures in Supabase Storage (`group-avatars/{groupId}/…`): the
//     script lists the prefixes to remove from the Supabase dashboard.
//
// WHY THE SERVICE ACCOUNT: groups are `delete: if false` in the rules, so no
// user can do this; a service-account token bypasses the rules.
//
// USAGE
//   node scripts/clear-groups.mjs [--apply] [--project ID]
//                                 [--key sa.json | --token ACCESS_TOKEN]
//
//   Run it WITHOUT --apply first and read the list. The key is the same
//   credential the push Worker uses (the FIREBASE_SERVICE_ACCOUNT secret); pass
//   a local copy and delete it afterwards. FIRESTORE_EMULATOR_HOST is honoured,
//   which is how it was tested.
//
// No dependencies: `fetch` and `crypto.subtle` are Node globals.

import { readFileSync } from 'node:fs';

const OAUTH_TOKEN_URI = 'https://oauth2.googleapis.com/token';
const SCOPE = 'https://www.googleapis.com/auth/datastore';
const PAGE_SIZE = 300;

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
clear-groups — delete every group (and its subcollections, join codes and
busy-notice rows). Schedule items and everything else are kept.

  node scripts/clear-groups.mjs [--apply] [--project ID]
                                [--key sa.json | --token ACCESS_TOKEN]

  --apply   actually delete (default: dry run, prints what would go)
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

const encodePath = (path) => path.split('/').map(encodeURIComponent).join('/');

function makeDb(projectId, token) {
  const emulator = process.env.FIRESTORE_EMULATOR_HOST;
  const origin = emulator
    ? `http://${emulator}`
    : 'https://firestore.googleapis.com';
  const root = `projects/${projectId}/databases/(default)/documents`;
  const base = `${origin}/v1/${root}`;
  const auth = { Authorization: `Bearer ${token}` };

  return {
    /** Document paths (relative to the database root) in a collection. */
    async listPaths(collection) {
      const out = [];
      let pageToken;
      do {
        const url = new URL(`${base}/${encodePath(collection)}`);
        url.searchParams.set('pageSize', String(PAGE_SIZE));
        // Also returns "missing" parents that only have subcollections.
        url.searchParams.set('showMissing', 'true');
        if (pageToken) url.searchParams.set('pageToken', pageToken);
        const resp = await fetch(url, { headers: auth });
        if (resp.status === 404) return out;
        if (!resp.ok) {
          throw new Error(`list ${collection} → ${resp.status}: ${await resp.text()}`);
        }
        const json = await resp.json();
        for (const d of json.documents || []) {
          out.push({
            path: d.name.slice(d.name.indexOf(root) + root.length + 1),
            fields: d.fields || {},
          });
        }
        pageToken = json.nextPageToken;
      } while (pageToken);
      return out;
    },

    /** Subcollection ids under a document. */
    async subcollections(docPath) {
      const ids = [];
      let pageToken;
      do {
        const resp = await fetch(`${base}/${encodePath(docPath)}:listCollectionIds`, {
          method: 'POST',
          headers: { ...auth, 'Content-Type': 'application/json' },
          body: JSON.stringify({ pageSize: 100, ...(pageToken ? { pageToken } : {}) }),
        });
        if (resp.status === 404) return ids;
        if (!resp.ok) {
          throw new Error(`listCollectionIds ${docPath} → ${resp.status}`);
        }
        const json = await resp.json();
        ids.push(...(json.collectionIds || []));
        pageToken = json.nextPageToken;
      } while (pageToken);
      return ids;
    },

    async deleteDoc(path) {
      const resp = await fetch(`${base}/${encodePath(path)}`, {
        method: 'DELETE',
        headers: auth,
      });
      if (!resp.ok && resp.status !== 404) {
        throw new Error(`delete ${path} → ${resp.status}: ${await resp.text()}`);
      }
    },
  };
}

/** Every document under [docPath], deepest first, then the document itself. */
async function collectTree(db, docPath) {
  const paths = [];
  for (const sub of await db.subcollections(docPath)) {
    for (const child of await db.listPaths(`${docPath}/${sub}`)) {
      paths.push(...(await collectTree(db, child.path)));
    }
  }
  paths.push(docPath);
  return paths;
}

const str = (fields, name) => fields?.[name]?.stringValue ?? '';

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(USAGE);
    return;
  }
  const { token, projectId } = await resolveAuth(args);
  const db = makeDb(projectId, token);
  console.log(`project: ${projectId}${process.env.FIRESTORE_EMULATOR_HOST ? ' (EMULATOR)' : ''}`);
  console.log(args.apply ? 'MODE: APPLY (deleting)\n' : 'MODE: dry run (nothing is deleted)\n');

  const groups = await db.listPaths('groups');
  const toDelete = [];
  for (const g of groups) {
    const tree = await collectTree(db, g.path);
    const members = g.fields?.memberUids?.arrayValue?.values?.length ?? 0;
    console.log(
      `group ${g.path.split('/')[1]}  "${str(g.fields, 'name')}"  ` +
      `${members} member(s), ${tree.length} doc(s) incl. subcollections`,
    );
    toDelete.push(...tree);
  }
  const codes = await db.listPaths('joinCodes');
  const notices = await db.listPaths('groupBusyNotices');
  toDelete.push(...codes.map((d) => d.path), ...notices.map((d) => d.path));

  console.log(
    `\n${groups.length} group(s), ${codes.length} join code(s), ` +
    `${notices.length} busy-notice row(s): ${toDelete.length} document(s) in all.`,
  );
  if (groups.length) {
    console.log('\nGroup pictures to remove from Supabase Storage (if any):');
    for (const g of groups) console.log(`  group-avatars/${g.path.split('/')[1]}/`);
  }

  if (!args.apply) {
    console.log('\nDry run only. Re-run with --apply to delete.');
    return;
  }
  let done = 0;
  for (const path of toDelete) {
    await db.deleteDoc(path);
    done += 1;
  }
  console.log(`\nDeleted ${done} document(s). Groups are cleared.`);
}

main().catch((e) => {
  console.error(e.message || e);
  process.exitCode = 1;
});
