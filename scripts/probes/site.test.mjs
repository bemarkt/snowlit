import test from 'node:test';
import assert from 'node:assert/strict';
import { startFixture, fixtureVersion } from './site.mjs';

async function setup(t) {
  const fixture = await startFixture();
  t.after(() => fixture.close());
  const created = await fetch(`${fixture.origin}/scenarios`, { method: 'POST' });
  assert.equal(created.status, 201);
  const scenario = await created.json();
  return { ...fixture, base: fixture.origin + scenario.path };
}

async function waitUntil(check) {
  const deadline = Date.now() + 2000;
  while (!(await check())) {
    assert.ok(Date.now() < deadline, 'Timed out waiting for observable fixture state');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

test('health identifies the exact fixture instance that owns the listening port', async t => {
  const first = await setup(t);
  const second = await setup(t);
  const health = await (await fetch(`${first.origin}/health`)).json();
  assert.equal(health.fixtureVersion, fixtureVersion);
  assert.equal(health.instanceID, first.instanceID);
  assert.notEqual(health.instanceID, second.instanceID);
});

test('ES module is self-contained and content preserves duplicate paragraphs and image roles', async t => {
  const { base } = await setup(t);
  const response = await fetch(`${base}module.mjs`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/javascript/);
  // Node checks module syntax/exports; DOM execution is explicitly an iOS test.
  const source = await response.text();
  const module = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
  assert.equal(module.fixtureVersion, fixtureVersion);
  assert.equal(typeof module.probe, 'function');
  const html = await (await fetch(`${base}content`)).text();
  assert.equal(html.match(/>重复段落</g).length, 2);
  assert.match(html, /data-probe-paragraph="p2"/);
  assert.match(html, /👩🏽‍💻 é &amp; text/);
  assert.match(html, /<img src="unmarked.svg">/);
});

test('redirect reaches the complete content and dynamic HTML has an observable ready marker', async t => {
  const { base } = await setup(t);
  const redirected = await fetch(`${base}redirect`);
  assert.equal(redirected.url, `${base}content`);
  assert.match(await redirected.text(), /合成章节/);
  const dynamic = await (await fetch(`${base}dynamic`)).text();
  assert.match(dynamic, /dataset.ready = 'true'/);
});

test('form login, rotation and logout invalidate previous synthetic credentials', async t => {
  const { base } = await setup(t);
  assert.equal((await fetch(`${base}protected`)).status, 401);
  const invalid = await fetch(`${base}auth/login`, { method: 'POST', body: 'password=wrong' });
  assert.equal(invalid.status, 401);
  const login = await fetch(`${base}auth/login`, { method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'password=fixture-password' });
  const oldCookie = login.headers.getSetCookie()[0].split(';')[0];
  assert.equal((await fetch(`${base}protected`, { headers: { Cookie: oldCookie } })).status, 200);
  const rotated = await fetch(`${base}auth/rotate`, { method: 'POST', headers: { Cookie: oldCookie } });
  const newCookie = rotated.headers.getSetCookie()[0].split(';')[0];
  assert.notEqual(oldCookie, newCookie);
  assert.equal((await fetch(`${base}protected`, { headers: { Cookie: oldCookie } })).status, 401);
  assert.equal((await fetch(`${base}protected`, { headers: { Cookie: newCookie } })).status, 200);
  const logout = await fetch(`${base}auth/logout`, { method: 'POST' });
  assert.match(logout.headers.getSetCookie()[0], /Max-Age=0/);
  assert.equal((await fetch(`${base}protected`, { headers: { Cookie: newCookie } })).status, 401);
});

test('API login uses JSON and credentials never authorize a different scenario', async t => {
  const first = await setup(t);
  const second = await setup(t);
  const login = await fetch(`${first.base}auth/login`, { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: 'fixture-password' }) });
  assert.equal(login.status, 200);
  const cookie = login.headers.getSetCookie()[0].split(';')[0];
  assert.equal((await fetch(`${second.base}protected`, { headers: { Cookie: cookie } })).status, 401);
});

test('fixture emits same-name cookies with distinct paths and echoes duplicates without a dictionary', async t => {
  const { base } = await setup(t);
  const result = await fetch(`${base}cookies/issue`);
  const cookies = result.headers.getSetCookie();
  assert.equal(cookies.length, 3);
  assert.equal(new Set(cookies.map(value => /Path=([^;]+)/.exec(value)[1])).size, 3);
  const echo = await (await fetch(`${base}nested/cookies`, {
    headers: { Cookie: 'probeCookie=nested; probeCookie=scenario; probeCookie=root' },
  })).json();
  assert.deepEqual(echo.cookies, ['probeCookie=nested', 'probeCookie=scenario', 'probeCookie=root']);
  // Cookie selection/storage itself is owned by the tested browser, not this server.
});

test('held requests release only after the test signals their gate', async t => {
  const { base } = await setup(t);
  const pending = fetch(`${base}wait/chapter`);
  await waitUntil(async () => (await (await fetch(`${base}status`)).json()).pending === 1);
  const released = await (await fetch(`${base}release/chapter`, { method: 'POST' })).json();
  assert.equal(released.released, 1);
  assert.deepEqual(await (await pending).json(), { released: 'chapter' });
});

test('host-cookie responses distinguish loopback hosts and include an intentionally invalid domain', async t => {
  const { base } = await setup(t);
  const named = new URL(base);
  named.hostname = 'localhost';
  for (const origin of [base, named.href]) {
    const response = await fetch(`${origin}cookies/host-issue`);
    assert.equal(response.status, 200);
    const cookies = response.headers.getSetCookie();
    assert.equal(cookies.length, 2);
    assert.equal(cookies[0].split(';')[0], `probeHost=${new URL(origin).hostname}`);
    assert.ok(!cookies[0].includes('Domain='));
    assert.match(cookies[1], /Domain=example\.invalid/);
    const cleared = await fetch(`${origin}cookies/host-clear`);
    assert.match(cleared.headers.getSetCookie()[0], /Max-Age=0/);
    assert.ok(!cleared.headers.getSetCookie()[0].includes('Domain='));
  }
  // This checks fixture behavior; only the Apple probes assess Cookie policy.
});

test('HTTP cancellation is observed and an independent subsequent request succeeds', async t => {
  const { base } = await setup(t);
  const controller = new AbortController();
  const pending = fetch(`${base}wait/cancel`, { signal: controller.signal });
  // Register the rejection handler before cancelling to avoid unhandled rejection races.
  const cancelled = assert.rejects(pending, { name: 'AbortError' });
  await waitUntil(async () => (await (await fetch(`${base}status`)).json()).pending === 1);
  controller.abort();
  await cancelled;
  await waitUntil(async () => (await (await fetch(`${base}status`)).json()).aborted === 1);
  assert.equal((await fetch(`${base}content`)).status, 200);
});

test('closing a scenario settles its pending requests and leaves other scenarios intact', async t => {
  const first = await setup(t);
  const created = await (await fetch(`${first.origin}/scenarios`, { method: 'POST' })).json();
  const other = first.origin + created.path;
  const pending = fetch(`${first.base}wait/close`);
  await waitUntil(async () => (await (await fetch(`${first.base}status`)).json()).pending === 1);
  assert.equal((await fetch(first.base, { method: 'DELETE' })).status, 200);
  assert.equal((await pending).status, 410);
  assert.equal((await fetch(`${first.base}content`)).status, 404);
  assert.equal((await fetch(`${other}content`)).status, 200);
});

test('server shutdown closes outstanding connections without releasing synthetic work', async t => {
  const fixture = await setup(t);
  const pending = fetch(`${fixture.base}wait/shutdown`);
  const rejected = assert.rejects(pending);
  await waitUntil(async () => (await (await fetch(`${fixture.base}status`)).json()).pending === 1);
  await fixture.close();
  await rejected;
  await fixture.close();
});
