import assert from 'node:assert/strict';
import test from 'node:test';

import {
  groupKeyBelongsTo,
  handleAvatarUpload,
  handleGroupAvatarDelete,
  handleGroupAvatarUpload,
  sniffImageMime,
} from '../src/avatar.js';

const env = {
  SUPABASE_URL: 'https://project.supabase.co/',
  SUPABASE_BUCKET: 'avatars',
  SUPABASE_SERVICE_KEY: 'service-role-key',
};

const pngBytes = new Uint8Array([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0,
]);

function uploadRequest(extraHeaders = {}) {
  return new Request('https://worker.example/avatar', {
    method: 'POST',
    headers: {'Content-Type': 'image/png', ...extraHeaders},
    body: pngBytes,
  });
}

test('byte sniffing accepts animated GIF and WebP containers', () => {
  const gif89a = new Uint8Array([
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0, 0, 0, 0, 0, 0,
  ]);
  const webp = new Uint8Array([
    0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
  ]);

  assert.equal(sniffImageMime(gif89a), 'image/gif');
  assert.equal(sniffImageMime(webp), 'image/webp');
});

test('uploads valid image bytes to the configured bucket and returns metadata', async () => {
  const originalFetch = globalThis.fetch;
  let seenUrl;
  let seenInit;
  globalThis.fetch = async (url, init) => {
    seenUrl = url;
    seenInit = init;
    return new Response('', {status: 200});
  };
  try {
    const response = await handleAvatarUpload(uploadRequest(), env, 'user-1');
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.match(
      seenUrl,
      /^https:\/\/project\.supabase\.co\/storage\/v1\/object\/avatars\/avatars\/user-1\//,
    );
    assert.equal(seenInit.method, 'POST');
    assert.equal(seenInit.headers.Authorization, 'Bearer service-role-key');
    assert.equal(seenInit.headers.apikey, 'service-role-key');
    assert.equal(seenInit.headers['Content-Type'], 'image/png');
    assert.match(body.url, /\/storage\/v1\/object\/public\/avatars\/avatars\/user-1\//);
    assert.match(body.key, /^avatars\/user-1\//);
    assert.equal(body.mime, 'image/png');
    assert.equal(body.sizeBytes, pngBytes.length);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('group deletion only touches keys under that exact group', async () => {
  const originalFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push([url, init]);
    return new Response('', {status: 200});
  };
  try {
    const foreign = new Request('https://worker.example/group-avatar', {
      method: 'DELETE',
      headers: {'X-Storage-Key': 'group-avatars/group-2/picture.png'},
    });
    const owned = new Request('https://worker.example/group-avatar', {
      method: 'DELETE',
      headers: {'X-Storage-Key': 'group-avatars/group-1/picture.png'},
    });

    assert.equal(
      (await handleGroupAvatarDelete(foreign, env, 'group-1')).status,
      200,
    );
    assert.equal(seen.length, 0);
    assert.equal(
      (await handleGroupAvatarDelete(owned, env, 'group-1')).status,
      200,
    );
    assert.equal(seen.length, 1);
    assert.equal(seen[0][1].method, 'DELETE');
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('contains a Supabase storage rejection without exposing its response body', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response('{"message":"provider detail must stay private"}', {
      status: 403,
    });
  try {
    const response = await handleAvatarUpload(uploadRequest(), env, 'user-1');
    const body = await response.json();

    assert.equal(response.status, 502);
    assert.deepEqual(body, {
      error: 'store-failed',
      reason: 'storage-authorization-failed',
      storageStatus: 403,
    });
    assert.doesNotMatch(JSON.stringify(body), /provider detail/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('group uploads use a group-scoped key and never a caller-controlled prefix', async () => {
  const originalFetch = globalThis.fetch;
  let seenUrl;
  globalThis.fetch = async (url) => {
    seenUrl = url;
    return new Response('', {status: 200});
  };
  try {
    const response = await handleGroupAvatarUpload(
      uploadRequest(),
      env,
      'group-1',
    );
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.match(seenUrl, /\/group-avatars\/group-1\//);
    assert.match(body.key, /^group-avatars\/group-1\//);
    assert.equal(groupKeyBelongsTo(body.key, 'group-1'), true);
    assert.equal(groupKeyBelongsTo(body.key, 'group-2'), false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('group replacement deletes only a previous key owned by that group', async () => {
  const originalFetch = globalThis.fetch;
  const methods = [];
  globalThis.fetch = async (_url, init) => {
    methods.push(init.method);
    return new Response('', {status: 200});
  };
  try {
    await handleGroupAvatarUpload(
      uploadRequest({
        'X-Previous-Key': 'group-avatars/group-2/foreign.png',
      }),
      env,
      'group-1',
    );
    assert.deepEqual(methods, ['POST']);

    methods.length = 0;
    await handleGroupAvatarUpload(
      uploadRequest({
        'X-Previous-Key': 'group-avatars/group-1/previous.png',
      }),
      env,
      'group-1',
    );
    assert.deepEqual(methods, ['POST', 'DELETE']);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
