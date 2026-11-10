import { readFileSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';

const resource = new URL('../../Packages/SnowlitKit/Sources/YingxueKit/Resources/SourceInspection/', import.meta.url);
const context = createContext(Object.create(null), {codeGeneration: {strings: false, wasm: false}});
for (const name of ['acorn.js', 'module-policy.js', 'inspect-source.js']) {
  runInContext(readFileSync(new URL(name, resource), 'utf8'), context, {filename: name});
}

export function inspectModule(source, requirements = []) {
  // This invokes only the trusted parser. No source string is evaluated or imported.
  return JSON.parse(JSON.stringify(context.snowlitInspectSource(source, requirements)));
}
