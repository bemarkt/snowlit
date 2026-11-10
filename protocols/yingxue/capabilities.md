# Protocol 1 candidate capability matrix

This matrix describes the candidate contract and its test coverage. A provided test is not a recorded pass. Native acceptance requires the complete iPhone verification for the same source revision. Product screens, installation activation, real websites and device performance require their own acceptance.

| Surface | Declaration and behavior | Corpus / native coverage |
| --- | --- | --- |
| `search`, `book`, `chapters`, `chapter` | Required exports; opaque references; paginated catalogs publish only after explicit completion; text/HTML/structured bodies normalize to one document model | Shared positive/negative wire corpus, native semantic tests, author example through WebKit and native HTTP/DOM |
| `authenticate` | Required when authentication is declared; submitted form/browser completion is separate from authenticated session | Managed form/cancellation, session verification and protected content in native author test; browser Cookie/form tests |
| `migrateReferences` | Required on reference-version changes; complete mapped or invalidated inventory; no silent merges or local-ID deletion | Wire corpus and native migration validator; atomic script activation belongs to installation integration |
| `migrateState` | Required on state-version changes; complete candidate with expected previous revision | Wire/native revision tests; adoption with active script belongs to installation integration |
| `http` | `http`; declared HTTP(S) origins; credential handles; explicit methods/bodies; per-hop redirect policy; native cookies | Native preparer/redirect negatives; actual URLSession author fixture and browser/native Cookie probes. The small author adapter disables redirects; it is not the production transport |
| `dom` | `dom`; one parse of supplied HTML, ordered text/HTML/attribute results, no resource loading or DOM handle | SwiftSoup semantic tests and native author fixture |
| `decodeText` | Explicit UTF-8, UTF-16LE/BE, Windows-1252, Latin-1, GB18030, Big5; invalid bytes fail | Apple CoreFoundation corpus; portable environments without CoreFoundation cannot validate the decoder |
| `interact` | Manifest authentication modes and origins; one native presentation ID; secret fields yield handles; cancellation is distinct | Native gate tests and actual browser form probes. The author test supplies a form decision; product form UI is separate |
| `readCredential` | `credentials.read` plus explicit installation/script-bound consent; updated script needs new consent | Native grant/revoke/late-result negatives; actual Keychain storage and managed HTTP use. Authorized plaintext can be used by the source |
| `readConfiguration` | Immutable public values at the operation's configuration revision; manifest defaults; reject unknown/duplicate/mistyped values | Wire/native exact-key and stale-revision tests; native host bridge reads the snapshot |
| `readPublicState`, `writePublicState` | `publicState`; installation/state version; transactional revision and native operation permits | Real SQLite conflict/revoke/reopen tests and native host tests; source-visible state contains no credentials |
| `openPage`, `evaluatePage`, `closePage` | `browser`; declared origins; operation/page/navigation ownership; isolated-world extraction; native resource cleanup | Native gate tests and actual dynamic WebKit extraction with delayed callbacks, navigation, cancellation and JSON failures |
| Cancellation and lifecycle | Full context/generation and distinct consumer tickets; stale replies rejected before adoption | Native gates; WebKit timeout/source/session tests; dedicated process-fault and real Home/activate fixtures |
| Text document semantics | Stable element/paragraph identity, UTF-16 mappings, supported text styles, preserved image/comment roles | Native normalizer/corpus; TextKit attachment, marker and page-curl feasibility probes. Images/comments/page-curl are not current product features |

The source runtime, website login view, and extraction view have distinct bridges and lifecycles. Content worlds do not isolate the DOM, browser networking or WebContent processes. A timeout only ends the waiter. Registry checks do not terminate JavaScript, and desktop process-fault injection is test infrastructure, not an iPhone runtime API.

No API allows a source to modify local books/checkpoints, execute native commands, access arbitrary files, or silently activate an upgrade. Unknown versions/fields/capabilities fail explicitly. Diagnostics must exclude private page contents, credentials and session data.
