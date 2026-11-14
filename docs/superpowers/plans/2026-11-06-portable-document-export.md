# Portable document export

> **For agentic workers:** Use superpowers:subagent-driven-development. Root runs validation; workers edit only their assigned files. No commit or publication is authorized by this plan.

**Goal:** Export a saved page or database as ordinary Markdown, HTML, CSV or searchable Korean PDF, together with its attachments, original structured source and a conversion report.

**Architecture:** Save pending edits, capture one selected body revision, validate its entire media snapshot, then build an immutable export bundle. All formats use a ZIP so the main document, database row pages, media and report stay together. Existing vault commits, Drive synchronization and Rust database calculations remain the source of truth.

**Tech stack:** Existing Dart/Flutter models, archive 4, pdf 3.12, FilePicker 13; existing Rust query runtime for computed database cells. An OFL Korean TrueType font is pinned for offline PDF generation.

**Spec:** docs/notion-feature-scope.md sections N1 and export; docs/obsidian-investigation.md. This completes selected-document export only. Whole-vault streaming, general Office fidelity, rich text, collaboration, actual S9+/Drive/external LLM acceptance and the full original goal remain required work.

## Constraints and reference evidence

- No private application code or assets are copied. REA uses the already pinned Obsidian 1.14.4 ASAR evidence; static traces are not runtime acceptance.
- Notion's public export contract describes Markdown with CSV database data and row pages, HTML with assets, and PDF. Obsidian's public storage contract describes ordinary Markdown files and local attachments. These guide independently implemented output.
- Official references checked 2026-11-06: https://www.notion.com/help/export-your-content and https://obsidian.md/help/data-storage .
- Preserve unknown JSON and every original snapshot file under `source/`. Report unresolved external document links, relations, computed errors, unsupported visual behavior and spreadsheet-safe CSV changes.
- Validate saved media bytes once. Never refetch each attachment from changing heads. Do not mutate the repository during conversion or destination selection.
- Escape HTML; no scripts, remote resource fetches or active URL schemes. Output paths are safe relative names, with stable UUID disambiguation.
- Snapshot input retains the existing 128MiB bound. A selected-document ZIP is not whole-vault streaming export.

## Review focus

- Saved revision changes or repository switches during async capture/rendering must not export another document under the old title.
- Unicode titles, path separators, duplicate names and Windows reserved basenames must not escape the archive or collide.
- Nested/unknown blocks, archived database rows, relations, formula errors and row attachments must not disappear silently.
- Long Korean paragraphs, tall tables and many columns must paginate in PDF and remain searchable.
- Cancellation and save/picker failures must preserve drafts and report no false success.

## Tasks

- [x] Core worker: tests first, then `lib/data/vault/portable_document_export.dart` and `test/workspace/portable_document_export_test.dart`. Pure builders consume validated page/database snapshots with fixed note/body/metadata identity. Database cell values use the existing query result contract. Main document, row pages, media, exact source files and `export-report.json` are packaged together.
- [x] PDF worker: tests first, then `lib/data/vault/portable_document_pdf.dart` and `test/workspace/portable_document_pdf_test.dart`. Render searchable Korean text and images without network requests, paginate long content, return explicit warnings.
- [x] Root: pin the official OFL TrueType font and reproducible preparation, integrate a format menu into StudyWorkspace, save then capture one revision, use FilePicker.saveFile and handle cancellation/failure. Add actual workspace integration regressions.
- [x] Root: run RED before implementation and focused GREEN after it. Independently inspect ZIP/CSV/HTML/Markdown and render/extract Korean PDF text. Run analysis and relevant existing saving/media/query tests once the changes stabilize.
- [x] Root: update existing history and feature scope with actual evidence and remaining requirements. Build60 remains the last packaged candidate until a later new build; do not claim new source changes are in it.

## Actual source validation

Current source677/7814149e… and test339/435 inventories stayed identical across the final checks. Whole Flutter: 1871 PASS, 108 skipped, no failures, 109 seconds; analysis: no issues, 9.5 seconds. New behavior coverage is 41 tests within that whole cohort, not an additional total. Reviewer regressions cover URI-encoded output paths, literal HTML inside Markdown tables and a real 128×5 PDF table spanning22 pages. An additional artifact probe passed7 tests (6 PDF tests overlap the whole suite) and Python independently read5 ZIP exports and5 final-source PDFs. Evidence lives in `build/validation/portable-document-export1/`.

Root's broad style command also changed16 unrelated package files. Their exact preflight bytes were recovered and independently verified in `style-restoration-verified1.json`; those changes are not part of this feature. There is no new Windows/Android package or device acceptance. Build60 and the original full product goal remain separate from this selected-document source checkpoint.

## Shared API

`PortableExportSource.page/database` captures `noteId`, `title`, `bodyRevisionId`, `metadataRevisionIds`, validated snapshot and optional evaluated `values` (`Map<rowId, Map<propertyId, DatabaseValue>>`). Getters `page` and `database` expose their respective snapshot or null.

`PortableExportFormat` contains markdown/html/csv/pdf. `buildPortableDocumentExport(source, format, {pdfBytes, pdfWarnings})` returns `PortableExportBundle` (`files`, `entrypoint`, `warnings`, `toZip()`). CSV is available for databases.

`renderPortableDocumentPdf(source, {ByteData? fontData})` returns `PortablePdfResult` (`bytes`, `warnings`). The default asset is `build/native/fonts/NotoSansKR-Portable.ttf`.
