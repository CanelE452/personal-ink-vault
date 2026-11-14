# Windows original Office editing engine

This module uses an unmodified LibreOffice 26.8.2.2 Windows x64 runtime privately,
through Python UNO. Flutter displays the editable objects inside Personal Ink
Vault; no user-installed Word, PowerPoint, or LibreOffice instance is automated.
It edits original document formats and derives a separate PDF from the saved,
reopened original.

## Preparation and distribution

Run `scripts/prepare-windows-office.ps1` from the repository. Python 3.11+ and
7-Zip are preparation dependencies. The official MSI is **375,934,976 bytes**;
the mapped runtime is **1,526,232,897 bytes** before the small PDF reader. The
download limit is 390 MB and extraction limit is 2 GB. The official SHA-256,
exact source URL, and the pinned PDF reader wheel are in `runtime.lock.json`.
Preparation extracts CAB members and reads MSI directory tables; it never runs
the installer or registers anything with Windows Installer.

Generated binaries stay under ignored `build/windows-office-engine/`. Preserve
the complete runtime directory, including `LICENSE.html`, `license.txt`,
`NOTICE`, third-party license files, and the Python/pdf-reader notices. The
official source corresponding to the distributed runtime is:

https://download.documentfoundation.org/libreoffice/src/26.8.2/libreoffice-26.8.2.2.tar.xz

For the Windows application bundle, copy:

- `build/windows-office-engine/runtime/` to `office_engine/runtime/` beside the
  application executable.
- `office_worker.py`, `office_text.py`, `office_images.py`, `office_word.py`, `office_word_layout.py`,
  `office_presentation.py`, `process_ownership.py`, `worker_job.ps1`, and
  `run-office.ps1` to `office_engine/` beside the executable.
- This README and `runtime.lock.json` to the same directory for provenance and
  source/license access.

No runtime files belong in Git. The app can also locate the prepared runtime
when launched from the repository during development. Do not describe a build
without the copied runtime as supporting Windows original editing.

## Contract

`WindowsOfficeEngine.inspect(sourcePath)` returns Word paragraphs/tables or
presentation slides/shapes. Shape geometry and slide dimensions use millimetres;
font sizes use points. Unknown/mixed/automatic style values are nullable.
Object IDs are local to the inspected source SHA. Pass that SHA as
`expectedSourceSha256` when applying changes.

Writer `paragraphs` and `blocks` remain body-only. `wordOwners` contains actual
header/footer text owners and their page-style references; equal text does not
merge distinct owners. Global tables carry an optional owner ID, established
through native table containment. Existing paragraph, cell, range and structure
operations address these source-bound IDs. Structural joins cannot cross an
owner boundary, and header/footer paragraph page breaks are rejected.
`pageStyles` reports nullable native layout observations and a raw-property hash;
this metadata does not expose page-setting or header visibility writes.

`inspect(sourcePath, preview: true)` additionally exports the loaded original
directly to PDF, without saving or rewriting the original format. The snapshot's
optional `previewPdfPath` and `previewPageCount` identify that initial preview.
The working input copy is still removed. The PDF remains in the request output
directory so the caller can materialize it for the editor, then release that
request directory. This is a source-bound initial preview, not a new edition.
Presentation PDF export includes hidden slides and omits note pages, keeping
every snapshot slide aligned with its corresponding preview page. The helper
rejects a slide/page count mismatch instead of overlaying objects on another
slide's image.

`apply(sourcePath, operations: ..., sessionId: ..., expectedSourceSha256: ...)`
accepts only the typed operations declared in the Dart adapter: paragraph text,
structure and style; table cell text; selected UTF-16 text ranges; shape text,
appearance and geometry; images; slide addition, deletion and ordering; and
existing master/layout selection and supported slide display flags. It returns
a new original file, a separate PDF, both
SHA-256 digests, the actual parsed PDF page count, and a snapshot read back from
the saved original. The input is copied into a fresh job directory and its hash
is checked again before reporting success. The existing vault revision remains
untouched; commit these new outputs through `OfficeDocumentStore`.

Presentations expose actual native master owners and layout codes 0/1/19/20.
Master template placeholders are read-only. A design request binds the current
design hash and a unique change namespace; surviving native objects retain their
IDs, and new objects receive aliases in that namespace. A layout change that
would discard nonempty or unverified content is rejected. Native masters are
not necessarily in one-to-one correspondence with OOXML master parts.
`includeDraftSnapshot: true` returns the source-bound live aliases for a private
preview; the separately reopened canonical snapshot identifies the saved file.
Only publishing through the document store creates a vault edition.

The native helper opens documents hidden with `MacroExecutionMode=0`
(`NEVER_EXECUTE`), `UpdateDocMode=0`, and an abort-only interaction handler.
Each job has a random named pipe, its own short temporary profile, and a Windows
Job Object. The process starts suspended, is assigned to that Job, and is then
resumed hidden. Closing the Job terminates only that owned process tree. The
Python launcher and its worker are also started suspended inside an outer owned
Job, so a timeout terminates both the launcher and the actual Python child.
No shell evaluation,
arbitrary UNO dispatch, document macros, user Office profile, or network service
is part of the request interface. Cleanup attempts to remove the owned profile;
locked files or forced OS termination can leave a small temporary profile.
The next job still uses a new isolated profile. Inspect input copies are removed
before returning. Requested preview PDFs and apply output directories remain
for the caller to materialize or commit/recover.

Slide reorder changes the OOXML slide ID order of an engine-generated staging
PPTX, then reopens it through LibreOffice and saves the requested original
format. The final original is reopened again before deriving its PDF. Explicit
shape resizing disables text auto-grow so the requested size survives saving;
OOXML geometry can round by a few hundredths of a millimetre.

## Actual runtime verification

Run `windows/office_engine/test-native.ps1` with `-RuntimePath` pointing to the
prepared runtime and `-OutputPath` naming a **new** output directory. It runs
hidden and creates only synthetic documents. It checks real DOCX heading/style
and table edits; PPTX shape text/style/geometry; slide add/delete/reorder; saved
original reopen; PDF page count and text; input hash preservation; and rejection
of an unlisted operation. `result.json` contains the reopened values and output
hashes. The Dart tests verify interface contracts separately and do not stand in
for this actual runtime test.

## Limits

DOCX/PPTX have dedicated synthetic authoring fixtures. The presentation design
suite also checks PPT/ODP import and save; this does not establish complete
compatibility for those formats. DOC/ODT need additional format-specific
fixtures. Existing master decorations, images and supported background edits
are available; master creation/duplication/deletion and arbitrary custom layout
selection are not. Charts, animations, embedded objects, complex tables and
tracked changes require more UI and preservation testing. Non-image decoration
rotation/shear are outside the current master fingerprint comparison.
Shapes nested in groups are not exposed as
independent editable children. Whole-paragraph/whole-shape text or style edits
replace that range's formatting. Original editions remain available for recovery.
HWP 5/HWPX are explicitly unsupported by this editing backend. A generated PDF
alone is never reported as a successful original edit. See
`docs/mvp-validation.md` for the current source/build acceptance checkpoint.

## Primary references

- [Official binary/checksum metadata](https://download.documentfoundation.org/libreoffice/stable/26.8.2/win/x86_64/LibreOffice_26.8.2_Win_x86-64.msi.mirrorlist)
- [LibreOffice startup/profile options](https://help.libreoffice.org/latest/en-US/text/shared/guide/start_parameters.html)
- [UNO Desktop](https://api.libreoffice.org/docs/idl/ref/servicecom_1_1sun_1_1star_1_1frame_1_1Desktop.html)
- [UNO draw pages](https://api.libreoffice.org/docs/idl/ref/interfacecom_1_1sun_1_1star_1_1drawing_1_1XDrawPages.html)
- [Shape text and auto-grow properties](https://api.libreoffice.org/docs/idl/ref/servicecom_1_1sun_1_1star_1_1drawing_1_1TextProperties.html)
- [Macro execution constants](https://api.libreoffice.org/docs/idl/ref/namespacecom_1_1sun_1_1star_1_1document_1_1MacroExecMode.html)
- [PDF export options](https://help.libreoffice.org/latest/en-US/text/shared/guide/pdf_params.html)
