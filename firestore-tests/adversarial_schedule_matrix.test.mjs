import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, it } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { doc, setDoc, updateDoc } from 'firebase/firestore';

const TARGET = 'target';
const PLANNER = 'planner';
const OUTSIDER = 'outsider';
const GROUP = 'g1';
const ITEM = `scheduleItems/${TARGET}/items/i1`;
let env;

const as = (uid) => env.authenticatedContext(uid).firestore();
const payload = (overrides = {}) => ({
  targetUid: TARGET,
  createdByUid: PLANNER,
  groupId: GROUP,
  title: 'Study',
  localWallTime: '2026-08-25T19:00',
  timezone: 'Asia/Kolkata',
  scheduledInstantUtc: new Date('2026-08-25T13:30:00Z'),
  status: 'pending',
  tier: 'normal',
  createdAt: new Date(),
  updatedAt: new Date(),
  ...overrides,
});

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-adversarial-schedule',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8') },
  });
});
after(async () => { await env.cleanup(); });
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `groups/${GROUP}`), {
      ownerUid: TARGET, memberUids: [TARGET, PLANNER], joinCode: 'ABC123',
    });
    await setDoc(doc(db, `groups/${GROUP}/plannerGrants/${PLANNER}_${TARGET}`), {
      plannerUid: PLANNER, targetUid: TARGET, groupId: GROUP,
      granted: true, grantedByUid: TARGET,
    });
  });
});

describe('schedule-item adversarial matrix', () => {
  it('allows the legitimate delegated create', async () => {
    await assertSucceeds(setDoc(doc(as(PLANNER), ITEM), payload()));
  });

  it('rejects every identity, lifecycle, and service-field forgery', async () => {
    const attacks = [
      { targetUid: OUTSIDER },
      { createdByUid: OUTSIDER },
      { groupId: 'other-group' },
      { status: 'approved' },
      { status: 'withdrawn' },
      { tier: 'emergency' },
      { outcome: { result: 'done' } },
      { notifiedCreated: true },
      { notifiedOutcome: 'done' },
      { notifiedAt: new Date() },
      { unknownInjectedField: 'surprise' },
    ];
    for (let i = 0; i < attacks.length; i++) {
      await assertFails(setDoc(
        doc(as(PLANNER), `scheduleItems/${TARGET}/items/attack-${i}`),
        payload(attacks[i]),
      ));
    }
  });

  it('outsider stays denied even with a perfectly shaped payload', async () => {
    await assertFails(setDoc(doc(as(OUTSIDER), ITEM),
      payload({ createdByUid: OUTSIDER })));
  });

  it('target decision cannot smuggle immutable-field changes', async () => {
    await setDoc(doc(as(PLANNER), ITEM), payload());
    await assertSucceeds(updateDoc(doc(as(TARGET), ITEM), {
      status: 'approved', decidedAt: new Date(), updatedAt: new Date(),
    }));
    const changes = [
      { title: 'Rewritten' },
      { scheduledInstantUtc: new Date('2030-01-01T00:00:00Z') },
      { timezone: 'UTC' },
      { targetUid: OUTSIDER },
      { createdByUid: TARGET },
      { groupId: 'other-group' },
      { tier: 'emergency' },
      { notifiedOutcome: 'done' },
    ];
    for (const change of changes) {
      await assertFails(updateDoc(doc(as(TARGET), ITEM), {
        ...change, updatedAt: new Date(),
      }));
    }
  });
});
