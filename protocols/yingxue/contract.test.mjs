import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseWireJSON, validate } from './validate.mjs';

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
