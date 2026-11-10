# Yingxue source contract candidate

`schema.json` is the single structural contract for protocol 1 metadata and reading operations. `scripts/generate_yingxue.py` generates the Swift models, Swift validation rules, TypeScript declarations, and the Swift copy of the shared corpus. Run the generator with `--check` to detect drift. Change the schema or corpus first, then regenerate.

The contract is a development candidate. Authentication host messages and runtime acceptance remain in progress; declaring a capability does not prove its iOS implementation. Static structure, semantic validation, host execution, and the App reading flow are distinct checks.

## Source file

A readable UTF-8 `.source.js` file starts with a JSON comment header:

```javascript
/* @yingxue
{
  "protocolVersion": 1,
  "sourceID": "org.example.reader",
  "name": "Example source",
  "scriptVersion": "1.0.0",
  "referenceVersion": 1,
  "stateVersion": 1,
  "capabilities": ["http", "dom"],
  "origins": [{ "scheme": "https", "host": "fixture.invalid" }],
  "authentication": [],
  "publicConfiguration": []
}
*/
```

An optional UTF-8 BOM and CRLF header line ending are accepted. The first `*/` closes the header; JSON text containing that sequence must escape the slash. The remainder is a self-contained ES Module. Metadata extraction does not execute the module, and a valid header alone is not installation acceptance.

The module exports `search`, `book`, `chapters`, and `chapter` as async, non-generator functions with two declared parameters `(ctx, input)`. Function declarations, async function expressions/arrows assigned to top-level variables, and local export aliases are accepted. Default exports and unknown exports are rejected. A source declaring any authentication mode also exports `authenticate`; reference/state upgrades may additionally export `migrateReferences`/`migrateState`. These names and the syntax edition (ECMAScript 2024) come from `x-module` in the schema.

Acorn 8.19.0 performs complete AST parsing without evaluating source code. The inspection rejects static imports, re-exports from another module, and dynamic import expressions anywhere in the AST. Import-like strings/comments are data and do not cause false matches. This is syntax and declared-shape validation, not a claim that arbitrary script behavior, generated code, networking, or resource usage is safe. Isolated host verification and runtime capability enforcement are still required. Parser reports contain only categories and line/column positions.

The official Acorn distribution and MIT license are bundled unchanged; `vendor.json` records the archive integrity and individual file hashes. The iOS inspection program and Node author tool use the same parser, policy, and inspection function. Callers pass source through a string argument, never interpolate it into the trusted program. The source digest covers the original file bytes, including header, BOM, and line endings.

`sourceID` identifies the author's source family. The host generates an installation ID, which remains stable across manual updates. Source responses cannot supply installation IDs or local book IDs. Names, account sessions, script versions, and digests are not local book keys. `scriptVersion` is an opaque display/version label, not an automatic update ordering rule.

Declared origins contain an exact lowercase DNS/IPv4 host, `http` or `https`, and an optional port. Default ports are 80 and 443. Duplicate effective origins are invalid, including an omitted port alongside its explicit default. These declarations describe requested scope; enforcement and redirects must also be checked by the host. They do not grant arbitrary WebKit networking by themselves.

Public settings support text, boolean, and explicit choices. Keys are unique exact UTF-8 identifiers. Choice values are unique and the initial value must exist. Public configuration contains no passwords, cookies, or tokens and is eligible for ordinary backup. `web` and `form` declare authentication needs; secret transport and storage are not defined by these labels.

## Reading operations

The generated declarations describe `search`, `book`, `chapters`, `chapter`, and optional `authenticate` inputs and outputs. `YingxueSource` and `SourceContext` signatures are generated from the schema's `x-operations` and `x-host` tables. Source references are opaque exact UTF-8 keys within the installation and `referenceVersion` captured by the host. Redirected URLs and display titles do not silently replace them.

`SearchInput.cursor`, `ChaptersInput.cursor`, and page `nextCursor` are required fields. JSON `null` begins or ends pagination explicitly; an omitted field or empty string is invalid. An empty search is valid. Only an explicitly ended directory becomes a complete catalog; repeated cursors, repeated chapter identities, or a changed catalog revision invalidate the assembly.

`ChapterResult.reference` must match the exact requested book/chapter. `revision` is the source's content revision. The `body.kind` discriminates text, HTML with explicit bindings, or structured blocks. All three go through [chapter normalization](normalization.md), which adds semantic validation and derives host fingerprints. A structural schema pass cannot prove that comment targets exist or that content contains readable text.

Unknown versions, fields, variants, and capabilities fail explicitly. Required nullable fields remain present during encoding. Numeric integers must fit the JavaScript safe integer range; fractional or overflowing identities are invalid. Duplicate JSON keys, including escaped equivalent keys, are rejected before model decoding so different parsers cannot select different versions or identities. Diagnostics contain schema paths and categories, not rejected values or unknown field names.

Use `YingxueWireCodec` at Swift wire boundaries. Direct `JSONDecoder` or `JSONEncoder` use alone does not enforce the schema. Generated model constructors are conveniences; the codec validates values before encoding. The author validator in `validate.mjs` reads the same schema and shared cases from `fixtures/wire.json`.

## Manual upgrades

An update must retain the source family ID and the host installation identity. `SourceUpgradeAssessment` reports newly requested capabilities, authentication modes, and effective origins for review. Changing `referenceVersion` requires explicit reference migration; changing `stateVersion` requires public state migration. The assessment never activates a script, resets state, substitutes chapters, or deletes local books. A failed or unapproved candidate leaves the current version usable.

For an update, pass the assessment to `SourceModuleInspection`; the changed version requires `migrateReferences` and/or `migrateState` exports. The author checker accepts `--previous <installed.source.js>` for the same static requirements. A migration export is only the first check: its output must validate before candidate activation.

`migrateReferences` receives the old/new reference versions and the exact saved book/chapter inventory. It returns a mapped or explicitly invalidated result for every old book and chapter. The host rejects omissions, unknown/duplicate references, version mismatches, and multiple old identities mapping to one new identity. An invalidated item retains its local book and saved data; it is not silently deleted or redirected to a similarly named item. No local book ID comes from the source. Mappings are candidate values until the installation update commits atomically. Paragraph anchors are not guessed or rewritten by this reference mapping.

Public state is an installation-scoped, versioned list of exact UTF-8 key/text values. A source may serialize structured public data into a text value. It must use the dedicated credential/session APIs for secrets. `readPublicState` returns the current version/revision; `writePublicState` requires that revision and returns either a committed snapshot or the current snapshot on conflict. A revision mismatch never silently overwrites new state. Empty initial state has revision 0. Every write increments the revision without exceeding the JavaScript safe-integer range.

The host's storage access session and individual operation permissions are checked in the same SQL transaction as the state write. Cancelling an operation revokes only its write permission; replacing the script/session revokes all old access. Backend owners must complete both runtime invalidation and storage revocation before reporting cancellation/logout/update complete. Used operation IDs cannot replay. Access tokens are native lifecycle metadata, never source-visible or restored as live permissions from an ordinary backup.

`migrateState` receives an immutable old snapshot. It returns the expected old revision and complete candidate entries for the new state version. Duplicate keys, stale revisions, and version mismatches fail. The old state remains available until the update transaction adopts the script and migrated state together; no migration is allowed to clear it on failure. Installation activation and backup/restore integration remain product work. The storage schema's additive version 1-to-2 migration preserves library/reading data and rolls back on failure; read-only opens requiring migration report it explicitly.

## Credentials

The host manages passwords/tokens separately from public settings and source state. A native form or trusted token capture stores a secret and issues a random `CredentialHandle` valid only for its current operation. The handle is not a persistent storage key. Passwords, cookies, tokens, and plaintext grants are excluded from ordinary backups and shareable logs. Keychain storage uses installation-specific services, device-only foreground accessibility, and no iCloud synchronization.

Host-managed transport can resolve a handle without granting plaintext to the source. Before sending a credential, it checks both the source's declared origin and the credential's narrower audience. It must repeat the check for every redirect and must not forward an already filled header/body blindly. The native value must never be encoded into a script callback, public state, or a diagnostic payload.

To read a stored secret, the source declares `credentials.read`. The install/upgrade UI separately asks the user to authorize the exact installation and source-file SHA-256. A declaration is not consent. Updated scripts need new confirmation even if the declaration is unchanged; `SourceUpgradeAssessment.credentialReadConsentRequired` reports this independently of added permissions. A refused update leaves the prior active version intact. The host can continue using managed credentials without plaintext consent.

`CredentialReadRequest` contains a temporary handle. Its authorized `CredentialReadResult` contains UTF-8 text. Missing, malformed, stale, and unauthorized requests fail explicitly. The host checks operation/session validity and consent before storage access and again after it returns. Logout, disablement, source replacement, operation closure, and cancellation invalidate outstanding handles. Revocation invalidates running operations; the backend owner must close their network/UI/runtime resources. Replacing a policy cannot reuse a revoked confirmation.

Native secret values are not Codable and redact printing/reflection. The dedicated sensitive wire result supports explicit transport encoding and redacts ordinary Swift diagnostics. This is not automatic taint tracking or guaranteed memory erasure: an authorized source can use the returned secret, including sending it to permitted sites. Transport logs and public-state/backup services must continue to enforce their own exclusions.

## Execution identity and results

The host creates an `OperationCall` with a protocol version, a typed request, and an `OperationContext`. Context contains a host request UUID, installation UUID, exact script SHA-256, public configuration revision, website session revision, and generation UUID. These identify execution validity; they do not become local book or reading-position keys. UUIDs and digests use canonical lowercase spelling.

`OperationReply` discriminates the four reading results, authentication result, and a structured failure. Every reply echoes the complete context and names the operation. Failures preserve a code, stage, and retryability hint; arbitrary error strings, scripts, HTML, and credentials are not shareable diagnostic fields. A retryability hint does not authorize replaying a website write.

`SourceOperationGate` owns active tickets for one installation. It validates a response against the host's ticket before returning it. Source replacement, configuration changes, login/logout, or disablement invalidate all tickets and return their request IDs so the backend owner can cancel network, browser, and UI resources. Closing is terminal. Cancellation of one ticket does not cancel another consumer, and a finished ticket cannot accept another result. An invalid replacement cannot destroy the current gate state.

Validating a reply keeps its ticket active while the caller normalizes or saves it. Check the ticket again after every suspension, then finish it explicitly. The receiving reader/search service also checks its navigation generation. Storage must keep its own transactional request/version predicates; a gate check before an asynchronous database call is not an atomic commit guard. This actor rejects stale results; it makes no claim to terminate JavaScript or reclaim WebContent CPU.

## Host calls

`HostCall` contains a call UUID, complete operation context, and a typed host request. `HostReply` echoes both IDs and returns that method's typed result or a classified failure. The operation gate rejects duplicate call IDs, mismatched replies, and replies after operation cancellation. Completing a host call reserves its ID until the enclosing operation ends, preventing replay of a website write. Backend dispatch must use the gate's host ticket and recheck it before sending a reply. An accepted envelope alone does not perform the requested capability.

`ctx.http` accepts an HTTP(S) URL/reference, an explicit method, headers, and an empty/byte/form body. Header and form values may use a credential handle with a prefix/suffix. The native preparer resolves those values against the credential audience, rejects control characters and host-owned transport/session headers, and encodes forms in UTF-8. Duplicate headers are rejected without regard to ASCII case; repeated form fields retain order. GET/HEAD cannot carry a body. Prepared native requests redact diagnostics and are not wire-serializable.

The transport disables automatic redirect forwarding. `SourceHTTPRedirects` resolves each Location against the preceding URL, checks the new declared origin, and enforces the caller's finite redirect budget. 303 changes methods other than HEAD to GET; 301/302 changes POST to GET; 307/308 preserve method/body. A cross-origin hop drops source headers and rejects a preserved body. A body intended for another authorized origin must be sent as a separate explicit source request. Each hop is prepared again so credential audiences and the current operation are rechecked. The transport handles cookies with its installation session before returning a response; `Set-Cookie` is omitted from source-visible headers. Status, final URL, other repeated headers, and raw bytes remain available. Errors are not silently replaced with successful empty content.

`ctx.decodeText` explicitly decodes base64 response bytes as UTF-8, UTF-16LE/BE, Windows-1252, Latin-1, GB18030, or Big5. Native decoding is strict; there is no automatic fallback that repairs invalid bytes. These encodings remain candidates pending Apple corpus verification. Decoding and parsing have separate contracts.

`ctx.dom` parses supplied HTML once and applies named CSS selections for text, inner HTML, or attributes. Results preserve document order. No matches return an empty array; a missing attribute returns null, while an explicitly empty attribute returns an empty string. Duplicate query keys or invalid selectors fail with categories, without echoing page text. The parser does not execute scripts or load resources; no DOM nodes cross the wire. Native execution uses the reviewed SwiftSoup dependency.

`ctx.interact` requests a native form or a website browser presentation. Forms declare public text/secret fields and credential origins; secret results contain operation-scoped handles. Required/mismatched/duplicate fields are checked before the reply is accepted. The host distinguishes user cancellation, a submitted form, and a completed browser interaction. Browser completion does not prove authentication: `authenticate` must verify the website session and return `authenticated` or `anonymous`. Only the host advances the session revision and invalidates prior work after accepting the result. The native presentation ID can complete once; cancellation, logout, disablement, or source replacement prevents late UI results from being adopted.

[fixture.source.js](examples/fixture.source.js) demonstrates search, detail, two-page catalog, a native credential form, session verification, and protected chapter extraction. The Node contract suite executes it with a deterministic host double and validates both operation and host messages. It is author-contract evidence, not a live website, native networking, WebKit, or App UI acceptance result.

## Dynamic pages

`ctx.openPage` opens a declared HTTP(S) origin in the installation's website session and returns a page ID, navigation ID, and final URL. Every permitted main-frame navigation, including redirects and website-initiated navigation, invalidates the previous navigation handle before loading starts. A result from an older navigation cannot be adopted. The native adapter must check each navigation and redirect, not just the initial URL and final reply. This origin check does not claim that every subresource, iframe, or browser request passes through `ctx.http`.

`ctx.evaluatePage` accepts the current handle, an asynchronous JavaScript function body, and `inputJSON`. The body receives the parsed value as `input` and returns a JSON-serializable value. The host passes input as data, evaluates in an isolated content world sharing the page DOM, and serializes the result into `PageEvaluation.json`. Page-world JavaScript globals and the source runtime's host bridge are not exposed in this world. This separation does not isolate DOM mutations, network access, or WebContent processes. Undefined, functions, symbols, BigInt, nonfinite numbers and cycles fail serialization rather than becoming successful empty content. Malformed JSON and duplicate object keys fail native validation. Page inputs and results may be private and must not enter shareable logs.

The host checks the operation and navigation before evaluation and after the native callback. Closing, navigation, cancellation, logout, source replacement, and disablement prevent late results. `ctx.closePage` accepts the page ID so a source can clean up after its navigation handle has expired; repeated close returns `closed: false`. Pages are owned by one operation and cannot be borrowed by another. The native owner closes the WebView, requests and other resources when the operation ends. The gate only invalidates registrations; it does not establish that JavaScript execution has stopped.

The App-hosted WebKit corpus exercises dynamic DOM extraction, isolated-world inputs, serialization failures, navigation and cancellation with delayed native callbacks. Until that corpus runs for the candidate SHA, portable tests establish only contract behavior.

## Local checks

```sh
python3 scripts/generate_yingxue.py --check
node --test protocols/yingxue/contract.test.mjs
node scripts/check_yingxue_source.mjs path/to/example.source.js
```

The Swift corpus and semantic tests run with YingxueKit's package tests. Node and portable Swift results establish contract behavior, not iOS WebKit compatibility.
