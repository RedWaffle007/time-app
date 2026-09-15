import assert from 'node:assert/strict';
import test from 'node:test';

import { handleAvatarUpload } from '../src/avatar.js';

const env = {
  SUPABASE_URL: 'https://project.supabase.co/',
  SUPABASE_BUCKET: 'avatars',
  SUPABASE_SERVICE_KEY: 'service-role-key',
};

const pngBytes = new Uint8Array([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0,
]);

function uploadRequest() {
  return new Request('https://worker.example/avatar', {
    method: 'POST',
    headers: {'Content-Type': 'image/png'},
    body: pngBytes,
  });
}

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
