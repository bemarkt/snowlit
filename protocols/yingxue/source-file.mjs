import { createHash } from 'node:crypto';
import { parseWireJSON, validate } from './validate.mjs';
import { inspectModule } from './module-inspector.mjs';

export function inspectSourceFile(bytes) {
  let source;
  try { source = new TextDecoder('utf-8', {fatal: true}).decode(bytes); }
  catch { throw new Error('invalidUTF8'); }
  const prefix = source.startsWith('/* @yingxue\r\n') ? '/* @yingxue\r\n' : '/* @yingxue\n';
  if (!source.startsWith(prefix)) throw new Error('missingHeader');
  const end = source.indexOf('*/', prefix.length);
  if (end < 0) throw new Error('unclosedHeader');
  if (!source.slice(end + 2).trim()) throw new Error('missingModule');
  const manifest = parseWireJSON(source.slice(prefix.length, end));
  validate('Manifest', manifest);
  const originKey = origin => `${origin.scheme}://${origin.host}:${origin.port ?? (origin.scheme === 'https' ? 443 : 80)}`;
  const origins = manifest.origins.map(originKey);
  if (new Set(origins).size !== origins.length) throw new Error('duplicateOrigin');
  if ((manifest.capabilities.includes('http') || manifest.capabilities.includes('browser') || manifest.authentication.length) && !origins.length) throw new Error('missingOrigins');
  const keys = new Set();
  for (const setting of manifest.publicConfiguration) {
    if (keys.has(setting.key)) throw new Error('duplicateSetting');
    keys.add(setting.key);
    if (setting.kind === 'choice') {
      const values = setting.choices.map(choice => choice.value);
      if (!values.length || new Set(values).size !== values.length || !values.includes(setting.initial)) throw new Error('invalidChoice');
    }
  }
  const report = inspectModule(source, manifest.authentication.length ? ['authenticate'] : []);
  validate('ModuleInspection', report);
  return {manifest, report, scriptSHA256: createHash('sha256').update(bytes).digest('hex')};
}
