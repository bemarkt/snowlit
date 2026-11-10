import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseWireJSON, validate } from './validate.mjs';
import { createHash } from 'node:crypto';
import { inspectModule } from './module-inspector.mjs';
import { inspectSourceFile } from './source-file.mjs';

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
