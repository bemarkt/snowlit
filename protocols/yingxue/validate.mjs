import { readFileSync } from 'node:fs';

// The author-side structural validator reads the same schema as the Swift generator.
const schema = JSON.parse(readFileSync(new URL('./schema.json', import.meta.url), 'utf8'));
const defs = schema.$defs;
const nameOf = value => value.$ref.slice('#/$defs/'.length);

export function parseWireJSON(text) {
  let result;
  try { result = JSON.parse(text); }
  catch { throw new Error('$: malformedJSON'); }
  let cursor = 0;
  const space = () => { while (/[\x20\t\r\n]/.test(text[cursor] ?? '\0')) cursor++; };
  const string = () => {
    space();
    const start = cursor++;
    while (cursor < text.length) {
      const char = text[cursor++];
      if (char === '"') return JSON.parse(text.slice(start, cursor));
      if (char === '\\') cursor++;
    }
    throw new Error('$: malformedJSON');
  };
  const value = () => {
    space();
    if (text[cursor] === '{') {
      cursor++; space();
      const names = new Set();
      if (text[cursor] === '}') { cursor++; return; }
      for (;;) {
        const key = string();
        if (names.has(key)) throw new Error('$: duplicateField');
        names.add(key);
        space(); cursor++; value(); space();
        if (text[cursor++] === '}') return;
      }
    } else if (text[cursor] === '[') {
      cursor++; space();
      if (text[cursor] === ']') { cursor++; return; }
      for (;;) { value(); space(); if (text[cursor++] === ']') return; }
    } else if (text[cursor] === '"') string();
    else { while (cursor < text.length && !/[\x20\t\r\n,\]}]/.test(text[cursor])) cursor++; }
  };
  value();
  return result;
}

export function validate(type, value, path = '$') {
  const rule = defs[type];
  const reject = reason => { throw new Error(`${path}: ${reason}`); };
  if (!rule) reject('unknownType');
  if (rule.oneOf) {
    if (value === null || typeof value !== 'object' || Array.isArray(value) || typeof value.kind !== 'string') reject('wrongType');
    const chosen = rule.oneOf.map(nameOf).find(name => defs[nameOf(defs[name].properties.kind)].const === value.kind);
    if (!chosen) reject('unknownVariant');
    return validate(chosen, value, path);
  }
  const nullable = Array.isArray(rule.type);
  if (nullable && value === null) return;
  switch (nullable ? rule.type[0] : rule.type) {
    case 'string':
      if (typeof value !== 'string') reject('wrongType');
      if ([...value].length < (rule.minLength ?? 0) || /[\uD800-\uDFFF]/u.test(value)) reject('invalidValue');
      if (rule.pattern && !new RegExp(rule.pattern, 'u').test(value)) reject('invalidValue');
      if (rule.enum && !rule.enum.includes(value)) reject('invalidValue');
      if (Object.hasOwn(rule, 'const') && value !== rule.const) reject('invalidValue');
      break;
    case 'integer':
      if (typeof value !== 'number') reject('wrongType');
      if (!Number.isSafeInteger(value) || value < (rule.minimum ?? -Number.MAX_SAFE_INTEGER) || value > (rule.maximum ?? Number.MAX_SAFE_INTEGER)) reject('invalidValue');
      if (Object.hasOwn(rule, 'const') && value !== rule.const) reject('invalidValue');
      break;
    case 'boolean':
      if (typeof value !== 'boolean') reject('wrongType');
      break;
    case 'array':
      if (!Array.isArray(value)) reject('wrongType');
      for (let index = 0; index < value.length; index++) {
        validate(nameOf(rule.items), value[index], `${path}[${index}]`);
        if (rule.uniqueItems && value.slice(0, index).some(item => equal(item, value[index]))) reject('duplicateItem');
      }
      break;
    case 'object':
      if (value === null || typeof value !== 'object' || Array.isArray(value)) reject('wrongType');
      if (Object.keys(value).some(key => !Object.hasOwn(rule.properties, key))) reject('unknownField');
      for (const key of Object.keys(rule.properties).sort()) {
        if (Object.hasOwn(value, key)) validate(nameOf(rule.properties[key]), value[key], `${path}.${key}`);
        else if (rule.required.includes(key)) throw new Error(`${path}.${key}: missingField`);
      }
      break;
    default: reject('unknownType');
  }
}

function equal(left, right) {
  if (typeof left !== typeof right || left === null || right === null) return left === right;
  if (Array.isArray(left) || Array.isArray(right)) return Array.isArray(left) && Array.isArray(right) && left.length === right.length && left.every((item, i) => equal(item, right[i]));
  if (typeof left === 'object') {
    const keys = Object.keys(left);
    return keys.length === Object.keys(right).length && keys.every(key => Object.hasOwn(right, key) && equal(left[key], right[key]));
  }
  return left === right;
}
