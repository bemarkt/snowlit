/* Trusted parser entry point. The source is only an Acorn input string. */
globalThis.snowlitInspectSource = function (source, requirements) {
  'use strict';
  requirements ??= [];
  const policy = globalThis.SnowlitModulePolicy;
  const rejected = (reason, node) => {
    const result = {kind: 'rejected', reason};
    if (node?.loc?.start) { result.line = node.loc.start.line; result.column = node.loc.start.column; }
    return result;
  };
  let tree;
  try { tree = globalThis.acorn.parse(source, {ecmaVersion: policy.ecmaVersion, sourceType: 'module', locations: true}); }
  catch (error) { return rejected('syntax', error.loc ? {loc: {start: error.loc}} : null); }

  // Visit every nested expression, including imports hidden inside unused functions.
  const pending = [tree];
  while (pending.length) {
    const node = pending.pop();
    if (node.type === 'ImportDeclaration' || node.type === 'ImportExpression' ||
        node.type === 'ExportAllDeclaration' || (node.type === 'ExportNamedDeclaration' && node.source)) {
      return rejected('externalModule', node);
    }
    for (const [key, value] of Object.entries(node)) {
      if (key === 'loc') continue;
      if (Array.isArray(value)) {
        for (const child of value) if (child && typeof child.type === 'string') pending.push(child);
      } else if (value && typeof value.type === 'string') pending.push(value);
    }
  }

  const bindings = new Map();
  const exports = new Map();
  function bind(node) {
    if (node.type === 'FunctionDeclaration' && node.id) bindings.set(node.id.name, node);
    if (node.type === 'VariableDeclaration') {
      for (const declaration of node.declarations) {
        if (declaration.id.type === 'Identifier') bindings.set(declaration.id.name, declaration.init);
      }
    }
  }
  for (const statement of tree.body) {
    if (statement.type === 'ExportDefaultDeclaration') return rejected('unknownExport', statement);
    if (statement.type === 'ExportNamedDeclaration') {
      if (statement.declaration) {
        const declaration = statement.declaration;
        bind(declaration);
        if (declaration.type === 'FunctionDeclaration' && declaration.id) {
          exports.set(declaration.id.name, {local: declaration.id.name, node: declaration});
        } else if (declaration.type === 'VariableDeclaration') {
          for (const item of declaration.declarations) {
            if (item.id.type !== 'Identifier') return rejected('invalidFunction', item);
            exports.set(item.id.name, {local: item.id.name, node: item});
          }
        } else return rejected('invalidFunction', declaration);
      }
      for (const specifier of statement.specifiers) {
        exports.set(specifier.exported.name ?? specifier.exported.value, {local: specifier.local.name, node: specifier});
      }
    } else bind(statement);
  }
  const allowed = new Set([...policy.requiredExports, ...policy.optionalExports]);
  for (const [name, declaration] of exports) {
    if (!allowed.has(name)) return rejected('unknownExport', declaration.node);
    const node = bindings.get(declaration.local);
    if (!node || !['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'].includes(node.type) ||
        !node.async || node.generator || node.params.length !== policy.parameterCount ||
        node.params.some(param => !['Identifier', 'ObjectPattern', 'ArrayPattern', 'AssignmentPattern'].includes(param.type))) {
      return rejected('invalidFunction', declaration.node);
    }
  }
  for (const name of [...policy.requiredExports, ...requirements]) {
    if (!allowed.has(name) || !exports.has(name)) return rejected('missingExport', tree);
  }
  return {kind: 'accepted', exports: [...exports.keys()].sort()};
};
