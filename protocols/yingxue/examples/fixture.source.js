/* @yingxue
{
  "protocolVersion": 1,
  "sourceID": "org.example.fixture",
  "name": "Synthetic reading fixture",
  "scriptVersion": "1",
  "referenceVersion": 1,
  "stateVersion": 1,
  "capabilities": ["http", "dom"],
  "origins": [{"scheme":"https","host":"fixture.invalid"}],
  "authentication": ["form"],
  "publicConfiguration": []
}
*/

// Author example. fixture.invalid is deliberately not a live website.
// The contract test supplies a synthetic host; native/iOS acceptance is separate.
async function getJSON(ctx, path) {
  const response = await ctx.http({target: {url: path, baseURL: 'https://fixture.invalid/'},
    method: 'get', headers: [], body: {kind: 'none'}});
  if (response.status === 401) throw {code: 'needsAuthentication', stage: 'http', retryable: false};
  if (response.status !== 200) throw {code: 'network', stage: 'http', retryable: false};
  const decoded = await ctx.decodeText({base64: response.base64, encoding: 'utf8'});
  return JSON.parse(decoded.text);
}

export async function search(ctx, input) {
  return getJSON(ctx, 'search?q=' + encodeURIComponent(input.query) + (input.cursor === null ? '' : '&cursor=' + encodeURIComponent(input.cursor)));
}

export async function book(ctx, input) {
  return getJSON(ctx, 'books/' + encodeURIComponent(input.reference.key));
}

export async function chapters(ctx, input) {
  return getJSON(ctx, 'books/' + encodeURIComponent(input.book.key) + '/chapters' + (input.cursor === null ? '' : '?cursor=' + encodeURIComponent(input.cursor)));
}

export async function chapter(ctx, input) {
  const page = await getJSON(ctx, 'books/' + encodeURIComponent(input.reference.book.key) + '/chapters/' + encodeURIComponent(input.reference.key));
  const selected = await ctx.dom({html: page.html, selections: [{kind: 'text', key: 'content', selector: 'main p'}]});
  return {reference: input.reference, revision: page.revision, body: {kind: 'text', text: selected.selections[0].values.join('\n\n')}};
}

export async function authenticate(ctx, input) {
  const form = await ctx.interact({kind: 'form', title: input.reason === 'expired' ? 'Sign in again' : 'Sign in',
    fields: [{kind: 'secret', key: 'password', label: 'Password', required: true}],
    credentialOrigins: [{scheme: 'https', host: 'fixture.invalid'}]});
  if (form.kind === 'cancelled') throw {code: 'cancelled', stage: 'interaction', retryable: false};
  if (form.kind !== 'submitted') throw {code: 'invalidData', stage: 'interaction', retryable: false};
  const field = form.fields.find(value => value.key === 'password' && value.kind === 'credential');
  if (!field) throw {code: 'invalidData', stage: 'interaction', retryable: false};
  const response = await ctx.http({target: {url: 'https://fixture.invalid/login'}, method: 'post', headers: [],
    body: {kind: 'form', fields: [{name: 'password', value: {kind: 'credential', handle: field.handle, prefix: '', suffix: ''}}]}});
  if (response.status !== 200) return {status: 'anonymous'};
  // Closing a form or receiving a 200 login page is insufficient: check the session.
  const verified = await getJSON(ctx, 'session');
  return {status: verified.authenticated ? 'authenticated' : 'anonymous'};
}
