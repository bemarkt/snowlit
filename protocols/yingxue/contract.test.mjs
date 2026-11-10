import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseWireJSON, validate } from './validate.mjs';
import { createHash } from 'node:crypto';
import { inspectModule } from './module-inspector.mjs';
import { inspectSourceFile } from './source-file.mjs';
import * as example from './examples/fixture.source.js';

const cases = JSON.parse(readFileSync(new URL('./fixtures/wire.json', import.meta.url), 'utf8'));
for (const fixture of cases) {
  test(fixture.name, () => {
    const check = () => validate(fixture.type, parseWireJSON(fixture.json));
    if (fixture.valid) assert.doesNotThrow(check);
    else assert.throws(check);
  });
}

test('diagnostics contain paths and categories without rejected values or unknown keys', () => {
  assert.throws(() => validate('BookReference', {key: '', password: 'synthetic-secret'}), error => {
    assert.equal(error.message, '$: unknownField');
    return true;
  });
  assert.throws(() => parseWireJSON('{"private":"a","private":"synthetic-secret"}'), error => {
    assert.equal(error.message, '$: duplicateField');
    return true;
  });
});

const modules = JSON.parse(readFileSync(new URL('./fixtures/modules.json', import.meta.url), 'utf8'));
for (const fixture of modules) {
  test(`module: ${fixture.name}`, () => {
    const report = inspectModule(fixture.source, fixture.requirements);
    validate('ModuleInspection', report);
    if (fixture.reason === null) assert.equal(report.kind, 'accepted');
    else {
      assert.equal(report.kind, 'rejected');
      assert.equal(report.reason, fixture.reason);
      assert.equal(JSON.stringify(report).includes('synthetic-private'), false);
    }
  });
}

test('vendored parser and license match the recorded official package bytes', () => {
  const vendor = JSON.parse(readFileSync(new URL('./vendor.json', import.meta.url), 'utf8'));
  const root = new URL('../../', import.meta.url);
  for (const file of vendor.files) {
    const digest = createHash('sha256').update(readFileSync(new URL(file.path, root))).digest('hex');
    assert.equal(digest, file.sha256);
  }
});

test('complete file inspection extracts metadata, parses source, and preserves raw digest identity', () => {
  const manifest = JSON.parse(cases.find(value => value.name === 'manifest-anonymous').json);
  const module = modules.find(value => value.name === 'unexecuted-top-level-throw').source;
  const makeFile = (metadata, prefix = '') => Buffer.from(prefix + '/* @yingxue\n' + JSON.stringify(metadata) + '\n*/\n' + module);
  const bytes = makeFile(manifest);
  const inspected = inspectSourceFile(bytes);
  assert.equal(inspected.report.kind, 'accepted');
  assert.equal(inspected.scriptSHA256, createHash('sha256').update(bytes).digest('hex'));
  const bom = inspectSourceFile(makeFile(manifest, '\uFEFF'));
  assert.equal(bom.report.kind, 'accepted');
  assert.notEqual(bom.scriptSHA256, inspected.scriptSHA256);
  assert.throws(() => inspectSourceFile(Buffer.from([255])), /invalidUTF8/);
  assert.throws(() => inspectSourceFile(makeFile({...manifest, origins: [...manifest.origins, {...manifest.origins[0], port: 443}]})), /duplicateOrigin/);
  assert.throws(() => inspectSourceFile(makeFile({...manifest, publicConfiguration: [...manifest.publicConfiguration, ...manifest.publicConfiguration]})), /duplicateSetting/);
  assert.throws(() => inspectSourceFile(makeFile({...manifest, origins: []})), /missingOrigins/);
  assert.equal(inspectSourceFile(makeFile({...manifest, authentication: ['web']})).report.reason, 'missingExport');
});

test('synthetic author source follows reading pagination and managed authentication contracts', async () => {
  const inspected = inspectSourceFile(readFileSync(new URL('./examples/fixture.source.js', import.meta.url)));
  assert.equal(inspected.report.kind, 'accepted');
  const schema = JSON.parse(readFileSync(new URL('./schema.json', import.meta.url), 'utf8'));
  const identity = {requestID: '11111111-1111-1111-1111-111111111111', installationID: '22222222-2222-2222-2222-222222222222',
    scriptSHA256: inspected.scriptSHA256, configurationRevision: 0, sessionRevision: 0, generation: '33333333-3333-3333-3333-333333333333'};
  const handle = {id: '44444444-4444-4444-4444-444444444444'};
  let loggedIn = false, cancelForm = false, sequence = 0;
  const captured = [];
  const book = {key: 'book'};
  const backends = {
    http: async request => {
      captured.push(request);
      const url = new URL(request.target.url, request.target.baseURL);
      assert.equal(url.origin, 'https://fixture.invalid');
      let value, status = 200;
      if (url.pathname === '/search') value = {items: [{reference: book, title: 'Synthetic book'}], nextCursor: null};
      else if (url.pathname === '/books/book') value = {reference: book, title: 'Synthetic book'};
      else if (url.pathname === '/books/book/chapters') {
        const last = url.searchParams.get('cursor') === 'page2';
        value = {book, revision: 'catalog-1', items: [{key: last ? 'c2' : 'c1', title: last ? 'Chapter 2' : 'Chapter 1'}], nextCursor: last ? null : 'page2'};
      } else if (url.pathname === '/login') {
        assert.equal(request.method, 'post');
        assert.deepEqual(request.body.fields[0].value, {kind: 'credential', handle, prefix: '', suffix: ''});
        loggedIn = true; value = {ok: true};
      } else if (url.pathname === '/session') value = {authenticated: loggedIn};
      else if (url.pathname.startsWith('/books/book/chapters/')) {
        status = loggedIn ? 200 : 401;
        value = loggedIn ? {revision: 'content-1', html: '<main><p>中文</p><p>第二段</p></main>'} : {error: 'needsAuthentication'};
      } else throw new Error('Unexpected fixture request');
      return {status, finalURL: url.href, headers: [], base64: Buffer.from(JSON.stringify(value)).toString('base64')};
    },
    decodeText: async request => ({text: new TextDecoder('utf-8', {fatal: true}).decode(Buffer.from(request.base64, 'base64'))}),
    dom: async request => {
      assert.equal(request.html, '<main><p>中文</p><p>第二段</p></main>');
      assert.deepEqual(request.selections, [{kind: 'text', key: 'content', selector: 'main p'}]);
      // A deterministic host fixture, not a Node DOM implementation or iOS evidence.
      return {selections: [{key: 'content', values: ['中文', '第二段']}]};
    },
    interact: async request => {
      assert.equal(request.kind, 'form');
      return cancelForm ? {kind: 'cancelled'} : {kind: 'submitted', fields: [{kind: 'credential', key: 'password', handle}]};
    },
    readCredential: async () => { throw new Error('The fixture never requests plaintext'); }
  };
  const ctx = {identity};
  for (const [method, contract] of Object.entries(schema['x-host'])) {
    ctx[method] = async input => {
      const id = (++sequence).toString(16).padStart(8, '0') + '-0000-0000-0000-000000000000';
      validate('HostCall', {id, context: identity, request: {kind: method, input}});
      const value = await backends[method](input);
      validate(contract.output, value);
      validate('HostReply', {kind: method, id, context: identity, value});
      return value;
    };
  }
  const invoke = async (name, input) => {
    const contract = schema['x-operations'][name];
    validate(contract.input, input);
    const value = await example[name](ctx, input);
    validate(contract.output, value);
    validate('OperationReply', {kind: name, context: identity, value});
    return value;
  };
  assert.equal((await invoke('search', {query: 'Synthetic', cursor: null})).items[0].title, 'Synthetic book');
  assert.equal((await invoke('book', {reference: book})).reference.key, 'book');
  const first = await invoke('chapters', {book, cursor: null});
  const second = await invoke('chapters', {book, cursor: first.nextCursor});
  assert.equal(second.nextCursor, null);
  assert.notEqual(first.items[0].key, second.items[0].key);
  const input = {reference: {book, key: first.items[0].key}};
  await assert.rejects(() => invoke('chapter', input), error => error.code === 'needsAuthentication');
  cancelForm = true;
  await assert.rejects(() => invoke('authenticate', {reason: 'signIn'}), error => error.code === 'cancelled');
  assert.equal(loggedIn, false);
  cancelForm = false;
  assert.equal((await invoke('authenticate', {reason: 'expired'})).status, 'authenticated');
  const content = await invoke('chapter', input);
  assert.equal(content.body.text, '中文\n\n第二段');
  assert.equal(JSON.stringify(captured).includes('synthetic-secret'), false);
});

test('upgrading metadata requires explicit migration exports and a fresh credential review', () => {
  const previousBytes = readFileSync(new URL('./examples/fixture.source.js', import.meta.url));
  const original = previousBytes.toString('utf8');
  const candidate = original.replace('"referenceVersion": 1', '"referenceVersion": 2').replace('"stateVersion": 1', '"stateVersion": 2')
    .replace('"http", "dom"', '"http", "dom", "credentials.read"');
  const rejected = inspectSourceFile(Buffer.from(candidate), {previousBytes});
  assert.equal(rejected.report.reason, 'missingExport');
  assert.equal(rejected.upgrade.referenceMigrationRequired, true);
  assert.equal(rejected.upgrade.publicStateMigrationRequired, true);
  assert.equal(rejected.upgrade.credentialReadConsentRequired, true);
  const complete = Buffer.from(candidate + '\nexport async function migrateReferences(ctx, input) {}\nexport async function migrateState(ctx, input) {}');
  const accepted = inspectSourceFile(complete, {previousBytes});
  assert.equal(accepted.report.kind, 'accepted');
  const repeated = inspectSourceFile(complete, {previousBytes: complete});
  assert.equal(repeated.upgrade.referenceMigrationRequired, false);
  assert.equal(repeated.upgrade.publicStateMigrationRequired, false);
  assert.deepEqual(repeated.upgrade.addedCapabilities, []);
  assert.equal(repeated.upgrade.credentialReadConsentRequired, true);
  assert.throws(() => inspectSourceFile(Buffer.from(original.replace('org.example.fixture', 'org.example.different')), {previousBytes}), /differentSource/);
});
