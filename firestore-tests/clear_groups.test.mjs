// The one-off group reset (scripts/clear-groups.mjs, 2026-09-27), run for real
// against the emulator: the dry run deletes nothing; --apply removes every
// group, its subcollections, join codes and busy-notice rows, and NOTHING else.
//
// Run: npm test

import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';

import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc } from 'firebase/firestore';

const PROJECT = 'demo-time-app';
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({ projectId: PROJECT });
});
after(async () => { await testEnv.cleanup(); });

function runScript(...flags) {
  return execFileSync(
    'node',
    ['../scripts/clear-groups.mjs', '--project', PROJECT, ...flags],
    { env: process.env, encoding: 'utf8' },
  );
}

async function seed() {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'groups/g1'), { name: 'Team', memberUids: ['a', 'b'] });
    await setDoc(doc(db, 'groups/g1/members/a'), { uid: 'a' });
    await setDoc(doc(db, 'groups/g1/memberStats/a'), { name: 'A' });
    await setDoc(doc(db, 'groups/g1/joinRequests/c'), { status: 'pending' });
    await setDoc(doc(db, 'groups/g2'), { name: 'Old', memberUids: ['a'] });
    await setDoc(doc(db, 'groups/g2/plannerGrants/x'), { granted: true });
    await setDoc(doc(db, 'joinCodes/ABC234'), { groupId: 'g1' });
    await setDoc(doc(db, 'groupBusyNotices/g1_a_b_1'), { sentAt: 'x' });
    // Must survive:
    await setDoc(doc(db, 'scheduleItems/b/items/i1'), {
      targetUid: 'b', createdByUid: 'a', groupId: 'g1', title: 'Run',
    });
    await setDoc(doc(db, 'friendships/a_b'), { uidA: 'a', uidB: 'b' });
    await setDoc(doc(db, 'users/a'), { name: 'A' });
  });
}

async function exists(path) {
  let found;
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    found = (await getDoc(doc(ctx.firestore(), path))).exists();
  });
  return found;
}

describe('clear-groups script', () => {
  it('a dry run lists everything and deletes nothing', async () => {
    await seed();
    const out = runScript();
    assert.match(out, /dry run/);
    assert.match(out, /2 group\(s\), 1 join code\(s\), 1 busy-notice row\(s\)/);
    assert.equal(await exists('groups/g1'), true);
    assert.equal(await exists('groups/g1/members/a'), true);
    assert.equal(await exists('joinCodes/ABC234'), true);
  });

  it('--apply removes every group trace and keeps everything else', async () => {
    await seed();
    runScript('--apply');
    for (const path of [
      'groups/g1', 'groups/g1/members/a', 'groups/g1/memberStats/a',
      'groups/g1/joinRequests/c', 'groups/g2', 'groups/g2/plannerGrants/x',
      'joinCodes/ABC234', 'groupBusyNotices/g1_a_b_1',
    ]) {
      assert.equal(await exists(path), false, path);
    }
    for (const path of ['scheduleItems/b/items/i1', 'friendships/a_b', 'users/a']) {
      assert.equal(await exists(path), true, path);
    }
  });

  it('is safe to re-run on an already-clear project', async () => {
    const out = runScript('--apply');
    assert.match(out, /0 group\(s\)/);
  });
});
