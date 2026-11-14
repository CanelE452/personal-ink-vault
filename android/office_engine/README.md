# Embedded Android Office editor

This Android library embeds the open-source Collabora Office editor in a private
Activity inside Personal Ink Vault. It does not launch a separate Office app or
send documents to a server. It requires Android API26 and an arm64 device.
Modern HWP/HWPX are deliberately absent from its editable-format capability.

`engine.lock.json` pins the official APK, its SHA-256, the source revision read
from that APK, and every Java/resource/header source file's SHA-256. Run
`scripts/prepare-office-engine.ps1` or `bash scripts/prepare-office-engine.sh`
from the repository. Preparation downloads at most260MB for the APK and394KB
of pinned source. Generated sources, the Office WebView UI, native libraries,
licenses, and source provenance go only into ignored `build/office-engine/`.
`-ApkPath` (PowerShell) or the first shell argument can reuse a local copy; it
must have the exact pinned SHA-256.

The upstream `android/lib` Java/resource source is generated with the explicit
`piv-8` embedded-close, preparation-cancellation, shared-message-thread, and
read-only-preview changes recorded in its generated provenance. Original edits
save a new original-format document and PDF before closing the embedded editor.
PDF-only preview forces read-only permission, suppresses source autosave and
editing messages, and starts export when the native engine reports a loaded
document. A terminal load error closes the preparation screen and reports the
failure, including when PDF conversion needs an unlocked copy. A validated PDF,
reported failure, or explicit cancellation returns to Flutter while the engine
closes. The app removes temporary files after the owning native session closes
and the caller relinquishes a successful result. Legacy format promotion and
publication of a reopened edited source retain their close confirmation.
Both paths release their WebView while keeping the Flutter task. Native document
open/save/close uses one process-wide FIFO, so external Activity destruction
queues close behind an unfinished export and never waits for COKit's close mutex
on the UI thread. Each native session closes once; a new Activity opens only
after the preceding close completes. The single native queue lives as long as
the process-wide COKit engine. Late callbacks to destroyed sessions are ignored.
An early close waits up to 10 seconds for the initial native HULLO handshake;
the owning WebView stays alive until close completes. A 45-second UI watchdog
covers native open/save/close. If either deadline expires, the engine is
quarantined for the rest of this process. An unfinished operation returns
`office_engine_restart_required`. Later Office requests fail immediately without
entering native code. Original and private working files remain and other app
features can continue. A late loading event cannot cancel the close watchdog. Recovery is
**force stop the app in Android Settings, then reopen**;
removing a recent-app card may leave the process alive. The app never kills its
own process or reuses a native session whose close could not be confirmed.
The upstream font cache path uses the application's directory.
These changes are reproducible in `prepare_engine.py`; the patch fails if the
pinned source no longer matches the read-only insertion points.

`python android/office_engine/test_lifecycle.py` extracts the generated Java
lifecycle method bodies into a deterministic queue harness. With a JDK available
it executes close-once, destroy during export/create, early cancellation,
save-failure retry, late handshake, timeout quarantine, blocked-close watchdog,
quick rejection of later requests, and cross-Activity ordering checks. This is a source-method
contract check, not an Android or JNI execution test.

`OfficeEngineBridge.edit(sourcePath, sessionId, Completion)` first copies the
materialized source into a new private `files/office-sessions/<uuid>` directory.
`OfficeEditorActivity` receives only that working-copy URI. On close, a small
JNI bridge calls the real COKit model's `saveAs` twice, retaining both boolean
results. Java validates the new Office package and opens the PDF with Android's
`PdfRenderer`, then returns new paths, SHA-256 values and PDF page count.
Failure keeps the editor and working copy available for retry. Cancelled or
interrupted sessions never return a saved revision. The caller imports only a
saved result into its revision store. Private session copies remain available
for recovery until that store has safely taken ownership.

`OfficeEngineBridge.preview(sourcePath, sessionId, Completion)` uses the same
private-copy preparation but launches a covered read-only Activity with only
progress and cancel controls. The preview uses that screen for progress so the
cancel button stays reachable. Restored temporary Activities require a matching
launch from the current app process. The preview calls COKit `saveAs` only for PDF, checks its
actual boolean result, checks source SHA-256 and modification time, and validates
the PDF with `PdfRenderer`. It returns `previewed` with the original source hash,
PDF path/hash/page count and session identity. Cancellation returns no new
edition. If native teardown exceeds its deadline after PDF validation, the
verified PDF still reaches the caller. The engine remains unavailable until the
process restarts, and the active engine's temporary files stay in place. An
unexpected close without a PDF reports a failure. Dart's `OfficePreviewEngine`
also checks the caller's source hash and modification time. **PDF로 새 문서 만들기**
saves a separate PDF and opens the shared handwriting editor. Read-only MCP
rendering uses the same converter.

## App integration

Add `com.android.library` version9.3.1 with `apply false` and
`include(":office_engine")` in `android/settings.gradle.kts`.
Add `implementation(project(":office_engine"))` to the app dependencies and
set its minSdk to26. Keep the app's existing libc++ duplicate rule and put
`../build/office-engine/generated/app-jni` in the app's main `jniLibs` source
directories so the pinned C++ runtime takes precedence over transitive copies.
Only the runtime is repeated there; the other engine libraries come from this
module.

Register a MethodChannel named `personal_ink_vault/office_engine` in
MainActivity. Route `capabilities` to `OfficeEngineBridge.capabilities()` and
`edit` and `preview` arguments `sourcePath`/`sessionId` to the matching methods. Forward
`onActivityResult` to `handleActivityResult` and call `dispose` in `onDestroy`.
`lib/data/office/android_office_engine.dart` is the typed Dart client. It rejects
same-path overwrite, mismatched-session or invalid-hash results. Original edit
requires both source and PDF outputs; preview requires only a separate PDF.

## Source and notices

The engine and UI come from Collabora's official open-source distribution,
not StarNote or Microsoft binaries. The matching full source is
<https://github.com/CollaboraOnline/online.mirror/tree/fd0b24ba59e043b2ed9087eb6324bbc6d281e93b>.
Its MPL and component notices are retained as `license.html`, `notice.txt`,
`office-engine-source-license.txt`, and `office-engine-provenance.json` inside
the built app. `prepare_engine.py` is the source of this project's generated
modifications. Preserve these notices and exact source links with releases.

Compilation is not a device test. Before reporting Android Office editing as
verified, test the installed APK on a device: edit DOCX text/style/table and
PPTX text/shape/slide, close, reopen the returned original-format revision, and
check its matching PDF. Also run PDF-only conversion without editing, verify
source bytes and timestamps, cancel during preparation/export, annotate the
generated PDF, and reopen the prior edition's handwriting. No connected Android
device was available during this integration work.
