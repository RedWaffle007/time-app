import assert from 'node:assert/strict';
import test from 'node:test';

import worker, { groupAvatarAuthorization } from '../src/index.js';

const env = { PROJECT_ID: 'demo-time-app' };

async function body(response) {
  return response.json();
}

test('the push endpoint is POST-only and advertises the allowed method', async () => {
  const response = await worker.fetch(
    new Request('https://worker.example/', { method: 'GET' }),
    env,
  );

  assert.equal(response.status, 405);
  assert.equal(response.headers.get('allow'), 'POST');
  assert.deepEqual(await body(response), { error: 'method-not-allowed' });
});

test('the avatar endpoint allows only POST and DELETE', async () => {
  const response = await worker.fetch(
    new Request('https://worker.example/avatar', { method: 'PUT' }),
    env,
  );

  assert.equal(response.status, 405);
  assert.equal(response.headers.get('allow'), 'POST, DELETE');
});

test('the group-avatar endpoint validates method and group before auth', async () => {
  const wrongMethod = await worker.fetch(
    new Request('https://worker.example/group-avatar', { method: 'PUT' }),
    env,
  );
  const missingGroup = await worker.fetch(
    new Request('https://worker.example/group-avatar', { method: 'DELETE' }),
    env,
  );
  const missingAuth = await worker.fetch(
    new Request('https://worker.example/group-avatar', {
      method: 'DELETE',
      headers: { 'X-Group-Id': 'group-1' },
    }),
    env,
  );

  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.headers.get('allow'), 'POST, DELETE');
  assert.equal(missingGroup.status, 400);
  assert.deepEqual(await body(missingGroup), { error: 'invalid-group' });
  assert.equal(missingAuth.status, 401);
  assert.deepEqual(await body(missingAuth), { error: 'unauthorized' });
});

test('group-avatar storage authorization is owner-only', () => {
  assert.deepEqual(groupAvatarAuthorization(null, 'owner'), {
    error: 'group-not-found',
    status: 404,
  });
  assert.deepEqual(
    groupAvatarAuthorization({ownerUid: 'owner'}, 'member'),
    {error: 'forbidden', status: 403},
  );
  assert.equal(
    groupAvatarAuthorization({ownerUid: 'owner'}, 'owner'),
    null,
  );
});

test('declared and actual oversized payloads are rejected before authentication', async () => {
  const declared = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    headers: { 'content-length': '2049' },
    body: '{}',
  }), env);
  const actual = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    body: 'x'.repeat(2049),
  }), env);

  assert.equal(declared.status, 413);
  assert.equal(actual.status, 413);
  assert.deepEqual(await body(declared), { error: 'payload-too-large' });
  assert.deepEqual(await body(actual), { error: 'payload-too-large' });
});

test('invalid JSON and invalid item bodies are distinct client errors', async () => {
  const invalidJson = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    body: '{',
  }), env);
  const invalidBody = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    body: JSON.stringify({ event: 'created', targetUid: 'target' }),
  }), env);

  assert.equal(invalidJson.status, 400);
  assert.equal(invalidBody.status, 400);
  assert.deepEqual(await body(invalidJson), { error: 'invalid-json' });
  assert.deepEqual(await body(invalidBody), { error: 'invalid-body' });
});

test('valid item-shaped requests require a bearer token', async () => {
  const response = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    body: JSON.stringify({
      event: 'created',
      targetUid: 'target',
      itemId: 'item-1',
    }),
  }), env);

  assert.equal(response.status, 401);
  assert.deepEqual(await body(response), { error: 'missing-token' });
});

test('friend events validate distinct parties; retired planning events are refused', async () => {
  const sameParty = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    body: JSON.stringify({
      event: 'friendRequest',
      fromUid: 'same',
      toUid: 'same',
    }),
  }), env);
  // 2026-09-27: friendship is the permission, so the planning-permission
  // events no longer exist — even a well-formed one is an invalid body.
  const missingKind = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    body: JSON.stringify({
      event: 'planningRequest',
      fromUid: 'sender',
      toUid: 'recipient',
      kind: 'normal',
    }),
  }), env);

  assert.equal(sameParty.status, 400);
  assert.equal(missingKind.status, 400);
  assert.deepEqual(await body(sameParty), { error: 'invalid-body' });
  assert.deepEqual(await body(missingKind), { error: 'invalid-body' });
});

test('avatar writes require authentication before touching storage', async () => {
  const response = await worker.fetch(new Request(
    'https://worker.example/avatar',
    { method: 'DELETE' },
  ), env);

  assert.equal(response.status, 401);
  assert.deepEqual(await body(response), { error: 'unauthorized' });
});

test('dismissed is an item event that requires a bearer token', async () => {
  const response = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    body: JSON.stringify({ event: 'dismissed', targetUid: 'target', itemId: 'item-1' }),
  }), env);

  assert.equal(response.status, 401);
  assert.deepEqual(await body(response), { error: 'missing-token' });
});

test('EVERY item event passes the request guard (unavailable was 400-ed)', async () => {
  // 2026-09-27 device bug: index.js kept its own event list without
  // `unavailable`, so the Uh-Oh push was rejected as invalid-body. The guard
  // now uses notify.js's ITEM_EVENTS; each event must reach auth (401).
  const { ITEM_EVENTS } = await import('../src/notify.js');
  assert.ok(ITEM_EVENTS.has('unavailable'));
  for (const event of ITEM_EVENTS) {
    const response = await worker.fetch(new Request('https://worker.example/', {
      method: 'POST',
      body: JSON.stringify({ event, targetUid: 'target', itemId: 'item-1' }),
    }), env);
    assert.equal(response.status, 401, event);
    assert.deepEqual(await body(response), { error: 'missing-token' }, event);
  }
});

test('group-join pushes need a safe group id before auth', async () => {
  const cases = [
    { event: 'groupJoinApproved', fromUid: 'member', toUid: 'candidate' },
    { event: 'groupJoinApproved', fromUid: 'member', toUid: 'candidate', groupId: '' },
    { event: 'groupJoinApproved', fromUid: 'member', toUid: 'candidate', groupId: 'a/b' },
    { event: 'groupJoinApproved', fromUid: 'same', toUid: 'same', groupId: 'group-1' },
  ];
  for (const payload of cases) {
    const response = await worker.fetch(new Request('https://worker.example/', {
      method: 'POST',
      body: JSON.stringify(payload),
    }), env);
    assert.equal(response.status, 400, JSON.stringify(payload));
    assert.deepEqual(await body(response), { error: 'invalid-body' });
  }

  const valid = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    body: JSON.stringify({
      event: 'groupJoinApproved',
      fromUid: 'member',
      toUid: 'candidate',
      groupId: 'group-1',
    }),
  }), env);
  assert.equal(valid.status, 401);
});

test('a join-request push needs a safe group id; a self-request is allowed', async () => {
  for (const payload of [
    { event: 'groupJoinRequested', fromUid: 'candidate', toUid: 'candidate' },
    { event: 'groupJoinRequested', fromUid: 'candidate', toUid: 'candidate', groupId: 'a/b' },
  ]) {
    const response = await worker.fetch(new Request('https://worker.example/', {
      method: 'POST',
      body: JSON.stringify(payload),
    }), env);
    assert.equal(response.status, 400, JSON.stringify(payload));
  }
  // The candidate asking for themselves passes validation and reaches auth.
  const self = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    body: JSON.stringify({
      event: 'groupJoinRequested', fromUid: 'candidate', toUid: 'candidate', groupId: 'group-1',
    }),
  }), env);
  assert.equal(self.status, 401);
});

test('voiceFallback is an item event that requires a bearer token', async () => {
  const response = await worker.fetch(new Request('https://worker.example/', {
    method: 'POST',
    body: JSON.stringify({ event: 'voiceFallback', targetUid: 'target', itemId: 'item-1' }),
  }), env);
  assert.equal(response.status, 401);
});
