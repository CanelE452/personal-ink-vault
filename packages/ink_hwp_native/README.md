# HWP5/HWPX native engine

Original application code is GPL-3.0-only. The actual reader/writer/model/renderer
libraries are pinned to STAIxBWLB/hwp-cli commit
`4e6e8c2a61694899e37b4f7c2f97523153a623b9` (MIT OR Apache-2.0 plus NOTICE).
This is a bounded original-format editor, not a claim of full Hancom compatibility.

`ink_hwp_request`, `ink_hwp_free`, `ink_hwp_version` implement the owned UTF-8 JSON
ABI. No CLI process, log scraping, cloud upload, or viewer automation is involved.
Null/invalid UTF-8/invalid JSON and panics return structured errors.

Requests use `mode: inspect|apply`, `sourcePath`, `outputDirectory`, and
`fontDirectories`. Apply additionally requires `sessionId`, `expectedSourceSha256`,
and a nonempty `operations` array. Inspect accepts `preview: true`.
Operations are `paragraphText {id,text}` and
`tableCellText {tableId,cell,text}`. IDs are source-bound positions such as
`s0:p0` and `s0:p1:t0`; cells use `row,col`. The source SHA precondition is required
by the native writer. Style, structural, nested-object, multi-paragraph-cell,
and non-whitespace control-character text edits are explicitly unsupported.
Tabs and line breaks are preserved as native inline controls; CRLF and CR
normalize to LF. HWPX replacement consumes only standard paragraph-namespace
self-closing tabs/line breaks with recognized attributes. Unknown children,
attributes, namespaces and opaque contents still block edits.

The normalized snapshot has `kind: word`, `sourceSha256`, `paragraphs`, `tables`,
and an empty `slides`. Successful apply returns `status: saved`, new working
`sourcePath`, `pdfPath`, both SHA-256 hashes, `pdfPageCount`, engineVersion and the
reopened snapshot. The caller can commit these as a new immutable revision only
after validation. No original input is overwritten. Failed edited source/PDF and
content-free diagnostics remain in the private working directory; no successful
result is returned for incomplete/clipped/failed rendering. The caller owns
successful working-file retention and eventual cleanup of failed workspaces.

HWP5 uses the pinned source-preserving rewrite API and verifies every non-target
stream/storage (the derived PrvText is intentionally refreshed). HWPX patches only
selected text spans and invalidated line caches, copying all other ZIP entries
without rebuilding the object model. Unknown/foreign XML in the dirty section,
unknown children in a replaced text node, nonstandard line-cache contents,
DOCTYPE, and unknown/external entities are rejected. Source snapshots and reopened
paragraph/table semantics are compared. Embedded image thumbnails are retained;
the generated PDF is the current app preview (`embeddedPreviewUpdated: false`).
Protected/password/distribution/DRM/signature documents are not decrypted.

The only render font is the hash-verified OFL Noto Sans CJK KR asset in
`fonts/manifest.json`. The original document font tables are preserved. PDF layout
uses an isolated clone of font metadata mapped to the bundled font and reports
`bundled_font_substitution`; it does not promise original-font metrics or visual
identity with Hancom. Incomplete/fatal/missing-font/clipped diagnostics block
success. Long table-cell pagination remains unsupported when the renderer reports
incomplete layout. Complex objects can be rejected even when plain text is readable.

Resource limits include 64MiB input, HWP 32MiB materialized streams, HWPX 32MiB
aggregate expansion/32MiB entry/2MiB XML, bounded XML depth/events/attributes,
500,000 semantic characters, image header checks (4MP each/16MP total), and bounded
layout (512 pages/250,000 display items). These are conservative support limits,
not a general hostile-document security certification.

Build with `scripts/build-hwp-native.ps1` or `.sh`; first prepare the generated
font assets with `scripts/prepare-hwp-fonts.ps1` or `.sh`. Outputs are ignored
`build/native/windows/ink_hwp_native.dll` and
`build/native/android/arm64-v8a/libink_hwp_native.so`.

Run `cargo test --locked --manifest-path packages/ink_hwp_native/Cargo.toml` after
font preparation. `cargo run --locked --manifest-path ... --example prepare_fixtures
-- build/native/hwp-fixtures` makes two original-format, synthetic test documents.
For the real Dart FFI tests set `INK_HWP_NATIVE_LIBRARY`,
`INK_HWP_FIXTURE_DIRECTORY`, and optionally `INK_HWP_FONT_DIRECTORY` before running
`test/office/hwp_engine_test.dart`. Those tests explicitly skip without the library
and fixture paths; the separate runner contract tests always run.

The license generator is reused from `../ink_vault_native/generate_licenses.py` via
`--manifest-path packages/ink_hwp_native/Cargo.toml`. The generated full bundle
covers the exact lockfile graph and pinned Git licenses/NOTICE plus the OFL font;
it is not a complete binary or application licensing audit.
