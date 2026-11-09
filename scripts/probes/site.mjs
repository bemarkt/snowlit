import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

export const fixtureVersion = 'runtime-probe-1';
export const contentHTML = `<!doctype html><html><head><title>合成章节</title></head><body>
<h1>测试章节</h1><p data-probe-id="p1">重复段落</p>
<p data-probe-id="p2">重复段落</p><p data-probe-id="p3">中文 👩🏽‍💻 é &amp; text</p>
<img src="illustration.svg" data-probe-role="illustration" alt="合成插图">
<img src="comment.svg" data-probe-role="comment" data-probe-paragraph="p2">
<img src="unmarked.svg"></body></html>`;

const moduleText = `export const fixtureVersion = ${JSON.stringify(fixtureVersion)};
export async function probe(baseURL) {
  const response = await fetch(new URL('content', baseURL));
  if (!response.ok) throw new Error('fixture HTTP ' + response.status);
  const document = new DOMParser().parseFromString(await response.text(), 'text/html');
  return {
    title: document.title,
    paragraphs: Array.from(document.querySelectorAll('p'), p => ({
      id: p.getAttribute('data-probe-id'), text: p.textContent
    })),
    images: Array.from(document.querySelectorAll('img'), image => ({
      role: image.getAttribute('data-probe-role'),
      paragraph: image.getAttribute('data-probe-paragraph')
    }))
  };
}`;

function send(response, status, body, type = 'application/json; charset=utf-8', headers = {}) {
  response.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', ...headers });
  response.end(type.startsWith('application/json') ? JSON.stringify(body) : body);
}

async function readBody(request) {
  const parts = [];
  let size = 0;
  for await (const part of request) {
    size += part.length;
    // This is a test-server request limit, not a source or chapter size limit.
    if (size > 8192) throw new Error('Fixture request body exceeds 8192 bytes');
    parts.push(part);
  }
  return Buffer.concat(parts).toString('utf8');
}

/** Isolated synthetic website. It never reads user files or contacts other hosts. */
export async function startFixture({ port = 0 } = {}) {
  const instanceID = randomUUID();
  const scenarios = new Map();
  const server = createServer((request, response) => {
    route(request, response).catch(error => {
      if (!response.headersSent && !response.destroyed) {
        send(response, 400, { error: error.message });
      } else {
        response.destroy();
      }
    });
  });

  async function route(request, response) {
    const url = new URL(request.url, 'http://127.0.0.1');
    if (url.pathname === '/health' && request.method === 'GET') {
      return send(response, 200, { fixtureVersion, instanceID });
    }
    if (url.pathname === '/scenarios' && request.method === 'POST') {
      const id = randomUUID();
      scenarios.set(id, { revision: 0, loggedIn: false, gates: new Map(), requests: [], aborted: 0 });
      return send(response, 201, { id, path: `/scenarios/${id}/`, fixtureVersion });
    }
    const match = /^\/scenarios\/([0-9a-f-]+)\/(.*)$/.exec(url.pathname);
    const scenario = match && scenarios.get(match[1]);
    if (!scenario) return send(response, 404, { error: 'Unknown fixture route or scenario' });
    const [, id, path] = match;
    const base = `/scenarios/${id}/`;
    // Observation polling must not grow the scenario's request history itself.
    if (path !== 'status') scenario.requests.push({ method: request.method, path });
    const sid = `synthetic-${id}-${scenario.revision}`;
    const cookie = request.headers.cookie ?? '';
    const cookieValues = cookie.split(';').map(value => value.trim());

    if (request.method === 'DELETE' && path === '') {
      for (const pending of scenario.gates.values()) {
        for (const waiting of pending) send(waiting, 410, { error: 'Scenario closed' });
      }
      scenarios.delete(id);
      return send(response, 200, { deleted: true });
    }
    if (request.method === 'POST' && path.startsWith('release/')) {
      const key = path.slice('release/'.length);
      const pending = scenario.gates.get(key) ?? new Set();
      const count = pending.size;
      for (const waiting of [...pending]) send(waiting, 200, { released: key });
      scenario.gates.delete(key);
      return send(response, 200, { released: count });
    }
    if (request.method === 'POST' && ['auth/login', 'auth/rotate', 'auth/logout'].includes(path)) {
      if (path === 'auth/logout') {
        scenario.loggedIn = false;
        scenario.revision += 1;
        return send(response, 200, { loggedIn: false }, undefined,
          { 'Set-Cookie': `sid=; Path=${base}; Max-Age=0; HttpOnly; SameSite=Lax` });
      }
      if (path === 'auth/rotate' && (!scenario.loggedIn || !cookieValues.includes(`sid=${sid}`))) {
        return send(response, 401, { error: 'sessionExpired' });
      }
      if (path === 'auth/login') {
        const body = await readBody(request);
        const password = request.headers['content-type']?.startsWith('application/json')
          ? JSON.parse(body).password : new URLSearchParams(body).get('password');
        if (password !== 'fixture-password') return send(response, 401, { error: 'invalidLogin' });
      }
      scenario.revision += 1;
      scenario.loggedIn = true;
      return send(response, 200, { loggedIn: true, revision: scenario.revision }, undefined,
        { 'Set-Cookie': `sid=synthetic-${id}-${scenario.revision}; Path=${base}; HttpOnly; SameSite=Lax` });
    }
    if (request.method !== 'GET') return send(response, 405, { error: 'Method not allowed' });
    switch (path) {
      case 'page':
        return send(response, 200, '<!doctype html><title>Snowlit probe</title><main>Ready</main>', 'text/html; charset=utf-8');
      case 'module.mjs':
        return send(response, 200, moduleText, 'text/javascript; charset=utf-8');
      case 'content':
        return send(response, 200, contentHTML, 'text/html; charset=utf-8');
      case 'dynamic':
        return send(response, 200, `<!doctype html><main id="content">Loading</main><script>
          setTimeout(() => { document.querySelector('#content').textContent = '动态合成正文';
            document.querySelector('#content').dataset.ready = 'true'; }, 30);
          </script>`, 'text/html; charset=utf-8');
      case 'login':
        return send(response, 200, `<!doctype html><form method="post" action="${base}auth/login">
          <label>合成密码<input type="password" name="password"></label><button>登录</button></form>`, 'text/html; charset=utf-8');
      case 'protected':
        return scenario.loggedIn && cookieValues.includes(`sid=${sid}`)
          ? send(response, 200, { text: '已认证合成正文', revision: scenario.revision })
          : send(response, 401, { error: 'sessionExpired' });
      case 'cookies/issue':
        return send(response, 200, { issued: true }, undefined, { 'Set-Cookie': [
          'probeCookie=root; Path=/; SameSite=Lax',
          `probeCookie=scenario; Path=${base}; SameSite=Lax`,
          `probeCookie=nested; Path=${base}nested/; HttpOnly; SameSite=Lax`,
        ] });
      case 'cookies':
      case 'nested/cookies':
        return send(response, 200, { cookies: cookieValues.filter(Boolean) });
      case 'redirect':
        return send(response, 302, '', 'text/plain', { Location: `${base}content` });
      case 'status':
        return send(response, 200, { requests: scenario.requests, aborted: scenario.aborted,
          pending: [...scenario.gates.values()].reduce((count, values) => count + values.size, 0) });
      case 'faults/never.mjs':
        return send(response, 200, 'export function run() { return new Promise(() => {}); }', 'text/javascript');
      case 'faults/spin.mjs':
        // Imported only by a separately supervised resource-recovery experiment.
        return send(response, 200, 'export function run() { while (true) {} }', 'text/javascript');
      default:
        if (path.startsWith('wait/')) {
          const key = path.slice('wait/'.length);
          const pending = scenario.gates.get(key) ?? new Set();
          pending.add(response);
          scenario.gates.set(key, pending);
          response.on('close', () => {
            pending.delete(response);
            if (!response.writableEnded) scenario.aborted += 1;
            if (pending.size === 0) scenario.gates.delete(key);
          });
          return;
        }
        return send(response, 404, { error: 'Unknown fixture route' });
    }
  }

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  let closing;
  return {
    instanceID,
    origin: `http://127.0.0.1:${server.address().port}`,
    close() {
      closing ??= new Promise((resolve, reject) => {
        server.close(error => error ? reject(error) : resolve());
        server.closeAllConnections();
      });
      return closing;
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.argv[2] ?? 18731);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid port');
  const fixture = await startFixture({ port });
  console.log(JSON.stringify({ origin: fixture.origin, fixtureVersion, instanceID: fixture.instanceID }));
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
    fixture.close().catch(error => { console.error(error.message); process.exitCode = 1; });
  });
}
