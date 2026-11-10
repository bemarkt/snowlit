import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {once} from 'node:events';
import {test} from 'node:test';
import {Worker, MessageChannel} from 'node:worker_threads';

const bootstrap = await readFile(new URL('../../Packages/SnowlitKit/Sources/YingxueKit/Resources/SourceExecution/worker.js', import.meta.url), 'utf8');
const schema = JSON.parse(await readFile(new URL('../../protocols/yingxue/schema.json', import.meta.url), 'utf8'));
const encode = text => new URL(`data:text/javascript;base64,${Buffer.from(text).toString('base64')}`);
const context = id => ({requestID: id, installationID: '10000000-0000-0000-0000-000000000000',
  scriptSHA256: 'a'.repeat(64), configurationRevision: 3, sessionRevision: 2,
  generation: '20000000-0000-0000-0000-000000000000'});
const call = (id, input = {query: '中文', cursor: null}) => ({protocolVersion: 1, context: context(id), request: {kind: 'search', input}});
const required = ['search'];

async function start(source) {
  // Only the browser event entry is adapted. The shipped bootstrap and private
  // MessagePort run unchanged. This does not validate WebKit scheduling or CSP.
  const shim = `import {parentPort} from 'node:worker_threads';
    const listeners = new Map();
    globalThis.addEventListener = (name, fn) => { const listener = data => fn({data}); listeners.set(fn, listener); parentPort.on(name, listener); };
    globalThis.removeEventListener = (name, fn) => parentPort.off(name, listeners.get(fn));
    globalThis.postMessage = value => parentPort.postMessage(value);
    process.on('unhandledRejection', () => {});
  `;
  const worker = new Worker(encode(shim + bootstrap));
  const {port1, port2} = new MessageChannel();
  const globalMessages = [], messages = [];
  worker.on('message', value => globalMessages.push(value));
  port1.on('message', value => messages.push(value));
  let cursor = 0;
  const next = async () => {
    const deadline = Date.now() + 2000;
    while (messages.length <= cursor) {
      assert(Date.now() < deadline, 'private port message deadline');
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    return messages[cursor++];
  };
  worker.postMessage({port: port2, moduleURL: encode(source).href, requiredExports: required,
    methods: Object.keys(schema['x-host'])}, [port2]);
  return {worker, port: port1, messages, globalMessages, next,
    invoke(value) { port1.postMessage({kind: 'invoke', id: value.context.requestID, json: JSON.stringify(value)}); },
    async configure() {
      const host = await next();
      const call = JSON.parse(host.json);
      assert.equal(host.kind, 'host'); assert.equal(call.request.kind, 'readConfiguration');
      port1.postMessage({kind: 'hostReply', id: host.id, json: JSON.stringify({kind: 'readConfiguration',
        id: host.id, context: call.context, value: {revision: call.context.configurationRevision, values: []}})});
    },
    async close() { await worker.terminate(); port1.close(); }};
}

test('private port runs real host messages and keeps immutable operation identity', async () => {
  const runtime = await start(`export async function search(ctx, input) {
    try { ctx.identity.requestID = 'spoofed'; } catch {}
    const settings = await ctx.readConfiguration({});
    return {query: input.query, settings, frozen: Object.isFrozen(ctx.identity)};
  }`);
  try {
    assert.deepEqual(await runtime.next(), {kind: 'ready'});
    const request = call('30000000-0000-0000-0000-000000000000');
    runtime.invoke(request);
    await runtime.configure();
    const host = await runtime.next();
    const parsed = JSON.parse(host.json);
    assert.equal(host.kind, 'host'); assert.equal(parsed.request.kind, 'readConfiguration');
    assert.deepEqual(parsed.context, request.context);
    const value = {revision: 3, values: [{kind: 'text', key: 'edition', value: '完整'}]};
    runtime.port.postMessage({kind: 'hostReply', id: host.id,
      json: JSON.stringify({kind: 'readConfiguration', id: host.id, context: request.context, value})});
    const reply = await runtime.next();
    assert.equal(reply.kind, 'result');
    assert.deepEqual(JSON.parse(reply.json), {kind: 'search', context: request.context, value: {query: '中文', settings: value, frozen: true}});
    assert.equal(runtime.globalMessages.length, 0);
  } finally { await runtime.close(); }
});

test('global postMessage cannot spoof module acceptance or expose the private port', async () => {
  const runtime = await start(`postMessage({kind: 'ready'});
    postMessage({kind: 'host', json: 'spoof'});
    export async function search(ctx, input) { return input; }
    throw new Error('secret top-level error');`);
  try {
    assert.deepEqual(await runtime.next(), {kind: 'failed'});
    assert.equal(runtime.globalMessages.length, 2);
    assert(!JSON.stringify(runtime.messages).includes('secret'));
    assert(!runtime.messages.some(message => message.kind === 'ready' || message.kind === 'host'));
  } finally { await runtime.close(); }
});

test('source errors cross as categories and pending host work prevents success', async () => {
  const runtime = await start(`export async function search(ctx, input) {
    if (input.query === 'throw') throw new Error('private page content');
    ctx.readConfiguration({}).catch(() => {});
    return {items: [], nextCursor: null};
  }`);
  try {
    await runtime.next();
    runtime.invoke(call('40000000-0000-0000-0000-000000000000', {query: 'throw', cursor: null}));
    await runtime.configure();
    const failed = JSON.parse((await runtime.next()).json);
    assert.deepEqual(failed.error, {code: 'invalidData', stage: 'execute', retryable: false});
    assert(!JSON.stringify(failed).includes('private page content'));
    runtime.invoke(call('50000000-0000-0000-0000-000000000000'));
    await runtime.configure();
    assert.equal((await runtime.next()).kind, 'host');
    assert.equal((await runtime.next()).kind, 'failed');
    assert.equal(runtime.messages.filter(message => message.kind === 'result').length, 1);
  } finally { await runtime.close(); }
});

test('sequential calls keep host IDs distinct and ignore a late prior reply', async () => {
  const runtime = await start(`export async function search(ctx, input) { return await ctx.readConfiguration({}); }`);
  try {
    await runtime.next();
    let previous;
    for (const id of ['60000000-0000-0000-0000-000000000000', '70000000-0000-0000-0000-000000000000']) {
      runtime.invoke(call(id));
      await runtime.configure();
      const host = await runtime.next();
      assert.notEqual(host.id, previous);
      if (previous) runtime.port.postMessage({kind: 'hostReply', id: previous, json: '{"value":"stale"}'});
      runtime.port.postMessage({kind: 'hostReply', id: host.id, json: JSON.stringify({kind: 'readConfiguration', value: id})});
      assert.equal(JSON.parse((await runtime.next()).json).value, id);
      previous = host.id;
    }
  } finally { await runtime.close(); }
});

test('top-level and operation infinite loops remain terminable through the private-port bootstrap', async () => {
  for (const atLoad of [true, false]) {
    const runtime = await start(atLoad ? `postMessage('entered'); while (true) {}` :
      `export async function search(ctx, input) { postMessage('entered'); while (true) {} }`);
    try {
      const entered = once(runtime.worker, 'message', {signal: AbortSignal.timeout(2000)});
      if (!atLoad) {
        await runtime.next(); runtime.invoke(call('80000000-0000-0000-0000-000000000000'));
        await runtime.configure();
      }
      assert.deepEqual(await entered, ['entered']);
      await runtime.worker.terminate();
      const count = runtime.messages.length;
      await new Promise(resolve => setTimeout(resolve, 50));
      assert.equal(runtime.messages.length, count);
      assert(!runtime.messages.some(message => message.kind === 'result'));
    } finally { await runtime.close(); }
  }
});
