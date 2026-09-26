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
      { notifiedDismissed: true },
      { approvalRemindersSent: 3 },
      { approvalRemindedAt: new Date() },
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
      { notifiedDismissed: true },
      { approvalRemindersSent: 3 },
      { approvalRemindedAt: new Date() },
    ];
    for (const change of changes) {
      await assertFails(updateDoc(doc(as(TARGET), ITEM), {
        ...change, updatedAt: new Date(),
      }));
    }
  });

  // Worker-only fields (2026-09-26): the target can never forge or reset the
  // approval-reminder counter or the dismiss dedup to silence a push, and the
  // planner cannot pre-stamp them to suppress one.
  it('only the Worker can write reminder and dismiss dedup fields', async () => {
    await setDoc(doc(as(PLANNER), ITEM), payload());
    for (const uid of [TARGET, PLANNER, OUTSIDER]) {
      for (const change of [
        { approvalRemindersSent: 3 },
        { approvalRemindersSent: 0 },
        { approvalRemindedAt: new Date() },
        { notifiedDismissed: true },
      ]) {
        await assertFails(updateDoc(doc(as(uid), ITEM), {
          ...change, updatedAt: new Date(),
        }));
      }
    }
  });

  // The Worker stamps these onto live items. Their presence must never block
  // the ordinary transitions (rules compare changed keys, not the whole doc).
  it('Worker-stamped fields never block approve, reject, withdraw or outcome', async () => {
    const stamps = {
      approvalRemindersSent: 2,
      approvalRemindedAt: new Date(),
      notifiedCreated: true,
      notifiedDismissed: true,
    };
    const seed = async (overrides) => env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), ITEM), payload({ ...stamps, ...overrides }));
    });

    await seed({});
    await assertSucceeds(updateDoc(doc(as(TARGET), ITEM), {
      status: 'approved', decidedAt: new Date(), updatedAt: new Date(),
    }));

    await seed({});
    await assertSucceeds(updateDoc(doc(as(TARGET), ITEM), {
      status: 'rejected', decidedAt: new Date(), updatedAt: new Date(),
    }));

    await seed({});
    await assertSucceeds(updateDoc(doc(as(PLANNER), ITEM), {
      status: 'withdrawn', withdrawnAt: new Date(), updatedAt: new Date(),
    }));

    await seed({ status: 'approved' });
    await assertSucceeds(updateDoc(doc(as(TARGET), ITEM), {
      outcome: { result: 'done', completedAt: new Date() },
      updatedAt: new Date(),
    }));
  });
});
