# HWP original paragraph alignment implementation plan

> **For agentic workers:** Use subagent-driven-development. Root executes tests, builds, REA and GUI. Workers may read files and edit only assigned files. Preserve the shared worktree. No commit, push, publication, candidate promotion or global settings changes. The user explicitly requested implementation without more questions.

**Goal:** Edit paragraph alignment in HWP5 and HWPX originals from Android and Windows, retain the original format and unrelated source data, reopen it and regenerate the PDF used by the existing annotation workflow.

**Architecture:** Extend the existing HWP Rust bridge with the existing `paragraphFormat` operation, restricted to `alignment`. Preserve source identity and paragraph text preconditions. Add a separate alignment capability to the existing Office editor; do not enable unrelated typography or structural operations. This is an implementation step toward full Office editing, not a redefinition of the full goal.

**Tech stack:** Existing pinned hwp-cli commit4e6e8c2, Rust HWP bridge, lexical HWPX patcher, Dart FFI and WindowsOfficeEditor shared by the HWP workflow. No new package/version. A direct reference to already-locked/transitive cfb0.14.0 supports source-raw style cloning in the owned HWP output and the exact CFB regression; its license is already present.

**Spec:** docs/requirements.md R1/R2/R6/R8, docs/hwp-engine-investigation.md and the user's original-format Office editing request. HWP and HWPX remain distinct formats; preview success does not imply original-format editing or universal layout fidelity.

## Constraints and review focus

- Four editable values: `left`, `center`, `right`, `justify`. Keep other source alignment values intact until explicitly changed.
- Wire operation: `{"op":"paragraphFormat","id":"s0:p0","expectedTextSha256":"<UTF8 SHA256>","alignment":"center"}`. No `styleName`, list, page break or unknown fields in this HWP operation.
- Validate the expected text against the original captured document before applying the batch, so text+alignment in either order is supported. Reject duplicate format operations for one paragraph and stale or malformed digests without publication.
- Reuse current source SHA/session/output ownership, rendering diagnostics and conditional repository publication. Do not mutate the input file or weaken unsupported-loss errors.
- HWP5: accept only verified append/reuse of ParaShape records differing from their source shape in alignment bits2..4. Existing DocInfo payloads and ID-mapping fields outside the exact paragraph-shape count must remain equal; preserve other streams and non-target source data.
- HWPX: retain the existing lexical writer. Clone the original paraPr raw XML, changing only id and align.horizontal; change only the target paragraph's paraPrIDRef and its known layout cache. Keep unrelated XML spans and ZIP entries exact. Do not call the model header writer which fills unknown attributes with defaults.
- Validate header ID mapping and namespaces before exposing/applying alignment; sparse/duplicate/out-of-order IDs must not silently become positional references. Existing text editing must retain its prior behavior when alignment cannot be offered.
- Existing rich text, cells, hyperlinks, unknown attributes/namespaces and source styles shared by other paragraphs must remain unchanged by an alignment-only edit.
- UI tools must fit320px and respect pending/save/error/reopen/snapshot replacement. The existing `allowFormatting` stays false for HWP; alignment has its own explicit flag and source metadata.

## Task1 — Rust original-format alignment and preservation

Owner: Rust worker. Files: packages/ink_hwp_native/src/engine.rs, src/xml.rs, any focused new module under src, focused tests/paragraph_alignment.rs. Existing tests/engine.rs remain intact unless root approves a necessary expectation change.

- [x] Write tests first for both source formats, all4 alignments, shared style isolation, text+alignment batch order, stale source/text, invalid/unknown operation fields, duplicate format, legacy text-only behavior, source and unrelated data preservation, HWPX namespaces/unknown XML and ambiguous IDs.
- [x] Root runs the focused tests and confirms genuine missing-feature RED.
- [x] Expose paragraphFormat.alignment in inspect/reopened snapshots and apply the source-bound format operation; extend exact preservation and lexical source writers.
- [x] Root runs focused and existing Rust tests, formatting/clippy and separate Windows DLL/Android ARM64 builds. No engine binary in existing candidate directories is overwritten.

## Task2 — Alignment-only shared HWP editor UI and Dart contract

Owner: UI worker. Files: lib/data/office/hwp_office_engine.dart, lib/pages/office/windows_office_editor.dart, lib/pages/office/office_workspace.dart and new focused test/office/hwp_alignment_editor_test.dart. Existing operation factory/model already support paragraphFormat; coordinate any unavoidable change with root.

- [x] Write real widget/contract tests first for four alignment actions, source text digest, combined text edits, dirty/save failure retry, disabled unsupported tools, absent metadata, replacement snapshots and320px layout.
- [x] Root observes RED before product edits.
- [x] Add WindowsOfficeEditor.allowParagraphAlignment=false. HWP workspace opts in while allowFormatting remains false. Use snapshot.paragraphFormat.alignment and existing paragraphFormat factory; expectedTextSha256 is the original paragraph UTF8 digest.
- [x] HwpOfficeEngine permits only the exact alignment operation contract, retains source/result validation and refuses images/unrelated format changes. Update the user notice to describe the actual text+alignment capability.
- [x] Root runs focused and existing Office/Study/MCP regressions and analysis.

## Task3 — Native integration, references and delivery evidence

Owner: root. Existing build/validation, guides and history structure are reused.

- [x] Record REA artifact identity and provider limitations separately from source API/format evidence and actual runtime behavior. The shipped hwp.exe is inspected without executing target instructions; a missing disassembler must not be described as successful decompilation.
- [x] Exercise the new actual DLL through Dart/FFI, persist both original formats, independently inspect alignment and unrelated bytes, and render/review fixed synthetic PDF outputs.
- [x] Audit the MCP HWP route and existing paragraphFormat schema; add actual SDK coverage if the operation reaches the existing tool.
- [x] Record exact source inputs, failures, final checks and remaining device/GUI/full-scope gates. Update guides/history. Build later installation candidates only from source-bound checks; this plan does not authorize commit/push/publication.

## Verified source state and delivery boundary

Runtime699/e01a600e3f183c8e7cc8a87b0a9aa42b1d3f6102a3f0d5490baa5da95ffe4fbc is unchanged before/after verification. Rust all-targets35PASS/0ignored, clippy0, Flutter2043PASS/106skip/0FAIL in1m59s and analysis0 passed. The actual HWP/HWPX Rust SDK stdio2 tests are included in the Flutter total; counts are not added. Separate E-staged Windows DLL7535616B/6964d6ff… and Android ARM64 SO9690888B/5a02fe5e… release builds, C ABI and four LOAD alignments0x4000 passed. No existing native/Release/candidate binary was overwritten.

The actual Windows DLL completed14requests/14frees and12 original-format save/reopen cases: four alignments and both text+format batch orders for each format. Independent Java readers, CFB/ZIP payload comparisons and pypdf text/position checks passed. Raw numbering reuse loss and foreign nested cache deletion were reproduced before fixes; strict boundary tests also cover uncompressed HWP. HWPX IR alignment follows the validated original unqualified attribute. Original RED/fixture/driver/compile/position failures remain retained in build/validation/hwp-alignment1.

Root directly reviewed the12 actual90dpi PDF PNG pages, six per format, for selected alignment, readable Korean/tables and visible clipping/overlap. Single-line justify has no visual difference; the saved original's alignment value was independently read. The bounded visual report is build/validation/hwp-alignment1/visual-review1.json,10117B/ec9678a8…. The combined checkpoint1.json is39339B/61d0e737…, generated with exit0 on attempt2. The first attempt's Windows ZIP hash transcription error is retained separately from product failures; the actual ZIP still matches its original64-digit manifest hash. The checkpoint combines prior actual checks bound to identical source maps and reverified artifact hashes; it does not claim all tests were rerun at checkpoint creation.

[User guide](../../hwp-paragraph-alignment.md), [validation](../../mvp-validation.md), history and handoff have been updated. This source-only feature and linked databases are absent from existing Android64/Windows62 installers; no new APK/ZIP, promotion, publication or commit/push occurred. Android compilation is not Android runtime acceptance. S9+/S Pen, standalone GUI, two real Drive devices, external LLM and the full Office/Notion/Obsidian goal remain open.
