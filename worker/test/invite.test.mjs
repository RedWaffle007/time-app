import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import worker from '../src/index.js';
import {
  APP_PACKAGE,
  assetLinks,
  handleInviteRequest,
  invitePage,
  parseInvitePath,
} from '../src/invite.js';

const env = {
  PROJECT_ID: 'demo',
  APP_CERT_SHA256: '1E:22:4B:C3:AF:38:AD:0B:C7:53:30:4D:30:30:12:0A:35:37:AF:6B:BB:3C:21:9B:27:36:84:03:47:09:7E:E8',
};
const get = (path, method = 'GET') =>
  new Request(`https://time-app-notify.timeapp.workers.dev${path}`, { method });

test('parser parity: the Worker agrees with every shared app fixture', () => {
  const fixture = JSON.parse(readFileSync(
    new URL('../../test/fixtures/invite_paths.json', import.meta.url), 'utf8',
  ));
  assert.ok(fixture.cases.length >= 20);
  for (const c of fixture.cases) {
    const parsed = parseInvitePath(c.path);
    if (c.kind === null) {
      assert.equal(parsed, null, c.path);
    } else {
      assert.deepEqual(parsed, { kind: c.kind, value: c.value }, c.path);
    }
  }
});

test('assetlinks: this package, only well-formed fingerprints', () => {
  const [statement] = assetLinks({
    APP_CERT_SHA256: `${env.APP_CERT_SHA256}, not-a-fingerprint, ab:cd`,
  });
  assert.deepEqual(statement.relation, ['delegate_permission/common.handle_all_urls']);
  assert.equal(statement.target.namespace, 'android_app');
  assert.equal(statement.target.package_name, APP_PACKAGE);
  assert.equal(APP_PACKAGE, 'com.timeapp.time_app');
  assert.deepEqual(statement.target.sha256_cert_fingerprints, [env.APP_CERT_SHA256]);
  assert.deepEqual(assetLinks({})[0].target.sha256_cert_fingerprints, []);
});

test('the deployed config carries a valid debug fingerprint', () => {
  const toml = readFileSync(new URL('../wrangler.toml', import.meta.url), 'utf8');
  const match = /APP_CERT_SHA256 = "([^"]*)"/.exec(toml);
  assert.ok(match);
  const prints = assetLinks({ APP_CERT_SHA256: match[1] })[0].target.sha256_cert_fingerprints;
  assert.equal(prints.length, 2, 'debug + release');
});

test('GET /.well-known/assetlinks.json serves JSON', async () => {
  const res = await worker.fetch(get('/.well-known/assetlinks.json'), env);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /application\/json/);
  const body = await res.json();
  assert.equal(body[0].target.package_name, APP_PACKAGE);
});

test('a friend invite page names the user and opens the app', async () => {
  const res = await worker.fetch(get('/i/u/Ana_B'), env);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/html/);
  assert.match(res.headers.get('content-security-policy'), /default-src 'none'/);
  const html = await res.text();
  assert.match(html, /@ana_b invited you to Checkmate/);
  assert.match(html, /intent:\/\/time-app-notify\.timeapp\.workers\.dev\/i\/u\/Ana_B#Intent;scheme=https;package=com\.timeapp\.time_app;end/);
  assert.match(html, /noindex/);
  assert.doesNotMatch(html, /<script/i);
});

test('a group invite page shows the code', async () => {
  const html = await (await worker.fetch(get('/i/g/hjk234'), env)).text();
  assert.match(html, /invited to a group/);
  assert.match(html, /<strong>HJK234<\/strong>/);
});

test('the download button appears only when configured', () => {
  const url = new URL('https://x.example/i/u/ana');
  const invite = { kind: 'user', value: 'ana' };
  assert.doesNotMatch(invitePage(invite, url, {}), /Get Checkmate/);
  assert.match(invitePage(invite, url, {}), /Ask the person who sent this/);
  const withLink = invitePage(invite, url, { APP_DOWNLOAD_URL: 'https://example.com/app?a=1&b="2"' });
  assert.match(withLink, /Get Checkmate/);
  assert.match(withLink, /href="https:\/\/example\.com\/app\?a=1&amp;b=&quot;2&quot;"/);
});

test('hostile or malformed invite paths get a plain 404, never a page', async () => {
  for (const path of [
    '/i/u/%3Cscript%3Ealert(1)%3C%2Fscript%3E',
    '/i/u/a%22onload%3D',
    '/i/g/XXXXXXXX',
    '/i/z/abc',
    '/i/u/%E0%A4%A',
  ]) {
    const res = await worker.fetch(get(path), env);
    assert.equal(res.status, 404, path);
    assert.match(res.headers.get('content-type'), /text\/plain/);
    assert.doesNotMatch(await res.text(), /<|script/i);
  }
});

test('invite handling never touches the push or avatar routes', async () => {
  // The push endpoint is still POST-only at the root.
  assert.equal((await worker.fetch(get('/'), env)).status, 405);
  // A POST to an invite path is not an invite page.
  assert.equal(handleInviteRequest(get('/i/u/ana', 'POST'), env), null);
  // Other GETs are not claimed by the invite feature.
  assert.equal(handleInviteRequest(get('/avatar'), env), null);
  // HEAD is served (link previews), like GET.
  assert.equal(handleInviteRequest(get('/i/u/ana', 'HEAD'), env).status, 200);
});
