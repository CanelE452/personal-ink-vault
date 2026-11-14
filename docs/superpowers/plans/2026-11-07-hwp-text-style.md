# HWP and HWPX selected text formatting implementation plan

> For agentic workers: use the existing TDD workflow; Root alone executes programs, tests, native builds and REA. Workers own only the files explicitly assigned to them.

**Goal:** Select text in an original HWP/HWPX document, change bold, size and color, keep editing text, and save both the original format and PDF through the existing Android/Windows/MCP flow.

**Architecture:** Keep the Flutter editor and the Rust HWP engine. Reuse the existing flat `textStyle` and `textReplace` Office DTOs, sequential UTF-16 coordinates and current-text SHA guards. Clone original raw character styles and patch only changed ranges; do not normalize unrelated styles or package members.

**Tech stack:** Existing Flutter/Dart, Rust, pinned hwp-cli revision 4e6e8c2 and existing C ABI. Add only unicode-segmentation=1.13.3, already pinned by the common Rust engine, for grapheme validation; no global configuration.

**Spec:** docs/requirements.md, docs/hwp-engine-investigation.md, docs/hwp-paragraph-alignment.md and the user's full Office/Obsidian/Notion/ink/Drive/MCP objective.

## Constraints

- Full objective stays active. This feature is progress, not completion of Office or Notion compatibility.
- No questions, commit/push/publication, promotion or mutation of frozen build65/64/62 candidates.
- Preserve unknown raw fields, non-target text/runs, other paragraphs/tables, source bytes and prior revisions. Reject ambiguous control/field mappings before writing.
- Ordinary paragraphs and single-paragraph table cells must retain their existing text editing capability. Rich snapshots must advertise only operations the engine implements.
- Source revision guards remain. Each text operation checks its own current text digest and UTF-16 range; malformed requests, surrogate/grapheme splits and unsupported style fields fail before publication.

## Review focus

- Korean, emoji, combining characters and empty insertion points; range shifts and inherited styles during typing.
- Multiple character runs sharing a style; unrelated fonts, decorations and unknown raw style bytes remain unchanged.
- HWP compressed/uncompressed CFB and HWPX foreign XML namespaces/extensions; untouched members retain their contents.
- Combined text/style/alignment requests; stale digest or later invalid operation publishes no partial output.
- UI selection, failed save/retry, back navigation and MCP use the same operation contract.

## Tasks

- [x] Rust worker: add failing public-engine tests in packages/ink_hwp_native/tests/text_style_ranges.rs; Root verifies RED before implementation.
- [x] Rust worker: implement range style and replacement plus accurate rich snapshots in engine.rs/xml.rs or focused modules matching existing structure. Root runs unit tests/clippy.
- [x] Root: add failing Dart request/editor tests; validate the flat DTO and enable only supported HWP character tools independently of general Office formatting. Preserve existing text/alignment/save behavior.
- [x] Root: build new owned Windows DLL and Android SO; verify actual C ABI, original-format independent reread and PDF rendering on synthetic multi-run HWP/HWPX inputs. Native build is not Android device execution.
- [x] Root: run relevant/full regression and analysis once stable; record actual evidence and remaining limits in the existing docs/history system. Packaging is a separate step after verified source.

## Evidence before implementation

Actual REA opened synthetic-original.hwpx (SHA60b009b73ecc6ebd39eb7aa01d5869fae22f9cc161de428a2ef94e05f39ce808) and returned complete archive inventory ev_7332f7c38da2cac2ff74b6cdbc5402c49a80416e8f16aa7848348090fb08f61f. Full receipt: build/validation/hwp-text-style1/rea-hwpx1.json. Package inventory does not prove HWP semantics or execution. Existing complete source and pinned raw-style APIs supply implementation references; actual engine execution is verified separately.

## Verified source feature — 2026-11-07

Final runtime701/SHA c3bbdf7c5231c32bd6b2c64abdf070f5074d0921016736876f1d26e45ae0174a, Git-test357 and test-tree453 have the same six before/after maps. Whole Flutter2090PASS/109skip/0FAIL in2m26s and analyze3/0issues in9.6s passed. Rust all-targets4 passed45/0ignored (16existing+16alignment+3boundaries+10range), and clippy2 exited0. Earlier focused/editor and later release tests overlap these paths and are not added to the whole count.

New Windows/Android HWP release libraries exited0 in176.49s/91.52s. DLL7753728bytes/SHA ad065d3817bdfbae631b0eeb0f89655b94712d80dd54f62c7290cb4ebffffa76; SO9913528bytes/SHA 2ae18f4aa7dafdc08a64abd3cc47c9a97a0111bfdfe9749a6cf2caa31170f516. Three C ABI exports and four Android0x4000 PT_LOAD segments were checked. Canonical native outputs remained unchanged.

Actual release DLL original/Java/PDF validation passed12cases with26requests/26frees. The12release PDFs exactly match Debug1 PDFs, so only the prior six-page90dpi visual observation is reused. Actual release Flutter6 (native2, alignment stdio2, character stdio2) passed0skip/exit0. The initial native2 failures were a missing-file fixture-path error; changing the input to build/native/hwp-fixtures led to native2 and final6 success. Original RED, compile, empty-origin, legacy-regression, lint and fixture-path failures remain preserved without weakening test expectations.

[Usage](../../hwp-text-style.md), [validation](../../mvp-validation.md), README/handoff/history and [checkpoint](../../../build/validation/hwp-text-style1/checkpoint1.json) record this source feature. Checkpoint-builder1 exited0 and produced10684bytes/SHA b36960067cfd60b51ec2fdeed81162bc8a79b3ff34c299f19d7f1b5738ef8e50, after rehashing current source/test maps, the175-package license/source pins and native/release/report inputs. This combines prior verified runs rather than rerunning the full suite during checkpoint creation. Build65 does not contain selected HWP text formatting; no new APK/Windows ZIP exists yet. S9+/S Pen, Android HWP/JSUNO runtime, standalone GUI, two physical Drive devices, external LLM acceptance and full Office/Notion/Obsidian functionality remain incomplete. These tasks are checked for the verified source feature only; the full user goal remains active and packaging is separate.
