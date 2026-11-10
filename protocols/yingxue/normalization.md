# Chapter normalization

Normalization version 1 converts text, HTML with explicit semantic bindings, or structured blocks into the same immutable chapter content. This is the normalization interface; source-file metadata and operation wire envelopes have separate contracts.

## Identity and text

A chapter retains its installation-qualified book/chapter reference and source content revision. Paragraphs, images, and comment entries have unique element identifiers within the document. Repeated text does not merge paragraphs. Opaque identifiers compare exact UTF-8 bytes; display text is not Unicode-normalized.

Text input converts CRLF and CR to LF, then uses each line as a paragraph, preserving empty lines and other whitespace. Generated identifiers are scoped to the resulting document. Cross-revision recovery must not assume that a generated paragraph identifier still names the same content.

HTML paragraph bindings map an exact HTML `id` to a source paragraph identifier. The host prefixes supplied identifiers with `source:` and generated identifiers with `generated:`. Missing or multiply matched bindings fail normalization. A bound paragraph cannot contain nested block paragraphs; the source must bind the actual paragraphs. Comment targets always use explicit source paragraph identities.

## HTML subset

- Paragraphs and headings preserve order; `h1` through `h6` retain their level.
- `strong`/`b` and `em`/`i` preserve nested emphasis. Inline CSS is ignored with a diagnostic. Other inline wrappers retain text and produce diagnostics when their presentation is unsupported.
- HTML ASCII whitespace collapses within ordinary text; leading/trailing paragraph spaces are removed. NBSP is preserved. `br` produces LF; `pre` preserves whitespace after line-ending normalization.
- Block containers split paragraphs. Empty `p` elements and explicitly bound paragraphs are retained.
- `img` remains an image unless the source explicitly supplies a comment role and target. Its position, source-scoped resource identity/reference, base URL, alternate text, MIME hint, and positive integral dimension hints are retained. A source binding can provide the reference for a lazy-loaded image. Invalid dimension hints produce diagnostics.
- An explicitly bound comment image becomes a native comment-entry description with its paragraph target and remote reference; the image resource remains available as its appearance description. No click script is preserved.
- Scripts, stylesheets, frames, objects, templates, embedded SVG/math markup, and document metadata are discarded with category diagnostics. HTML event attributes, link actions, and executable markup never enter the Core document. A `base` tag does not override the caller-supplied base URL.

Parsing uses the pinned SwiftSoup HTML parser on a background actor. Parsing creates data only: it does not load image/frame URLs or execute a page. The M1 text projection does not download or display body images and does not expose comment interactions. Resource descriptors are not evidence of a completed download or an offline image cache.

A chapter with no displayable text is an explicit empty-content failure. Invalid references, conflicting descriptions for one resource ID, duplicate elements, unknown normalization versions, and missing comment targets also fail; they do not become an empty successful chapter.

## Fingerprints and positions

The normalized content encodes as JSON with sorted fixed keys, unescaped slashes, ordered block/run arrays, and integral dimensions. `ChapterDocument` derives a SHA-256 revision from all normalized bytes and a separate SHA-256 digest from its UTF-8 text projection. Source-provided revision labels are included in the content; they are not trusted as the normalized fingerprint. Cached content must be decoded, validated, and hashed again before adopting its recorded fingerprint.

The complete fingerprint covers styles, resource descriptions, element order, and comment targets. A non-text change can therefore invalidate an exact reading position while retaining the same text digest. Layout choices such as font size, theme, and viewport dimensions are absent from the normalized content.

Text offsets use UTF-16 in the text-only projection. Runs are concatenated before determining extended grapheme boundaries, so an accent or emoji split across styled runs cannot create a valid position inside a grapheme. Paragraph separators belong to the preceding paragraph's end; following paragraphs start after the separator. Images/comment entries have explicit projection positions but contribute no replacement characters to M1 text offsets.

A reading position contains the chapter reference, normalized revision, normalization version, element ID, and paragraph-local UTF-16 offset. Resolution rejects another revision, missing paragraph, or invalid grapheme boundary. Any later approximate reading recovery must be explicit; comment targets must never use approximate text matching.

## Dependency

SwiftSoup 2.14.3 is pinned to `e7f85f4d3dd91ca9a1e94d3328aa1ed5120a8c0f`. Its MIT notice is retained in `Licenses/SwiftSoup.txt`. Only YingxueKit imports it; Core and Reader do not depend on the parser or DOM node types.
