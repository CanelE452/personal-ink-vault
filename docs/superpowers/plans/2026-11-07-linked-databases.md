# Linked databases in block pages implementation plan

> **For agentic workers:** Use subagent-driven-development. Root runs all tests/builds; assigned workers edit only their own files. No commit, push, publish, candidate promotion or global configuration changes. The user explicitly requested implementation without further questions.

**Goal:** Insert a linked database inside a block page, configure its own view/filter, and edit the original database's rows from that page on Android and Windows.

**Architecture:** A block stores the source note's stable ID and one independent DatabaseView. The existing DatabaseEditor renders/edits the real source snapshot and existing Rust DatabaseQueryRuntime computes the linked view. Source writes use a separate guarded NoteSession bound to the active owning page; page content and source database revisions stay independent.

**Tech stack:** Existing Flutter/Dart, Rust database query/action runtime, repository revision guards, media worker and Drive revision transport. No new dependency.

**Spec:** docs/notion-feature-scope.md section 2, docs/requirements.md R4/R6/R8 and the user's full active goal. Notion's [linked database contract](https://www.notion.com/da/help/guides/using-linked-databases) distinguishes original row changes from instance-local view/filter settings. Existing retained REA Obsidian reference evidence establishes source artifact identity and document-link mechanisms; it does not establish Notion database internals or runtime equivalence.

## Constraints and review focus

- Preserve APK64/Windows62 and all dirty work. This feature does not complete Office, Obsidian, Notion, collaboration, AI or device acceptance.
- A known linked-block format is strictly validated; opaque future formats and unrelated unknown JSON survive edits. Reference-only exports must declare that the live database is not embedded in an export.
- Link by source note UUID, never title/path. Renames preserve identity; deleted, conflicting, wrong-kind and missing sources produce an explicit unavailable state.
- Page-local view/filter changes never replace source database view definitions. Data edits change the source, and two pages observe the same source after reopen/refresh.
- Late callbacks after page close/repository switch and stale source metadata/body heads must not publish. Exact retry after a prepared/partially published save must preserve the existing idempotency contract.
- Unsaved or failed child edits prevent parent deletion/undo/navigation from discarding the child. Explicit save/back flush child editors before the page; 320px layout and nested row dialogs must remain usable.

## Task 1 — Block reference model and source projection

Ownership: model worker only: new lib/data/vault/block_page_linked_database.dart; lib/data/vault/block_page_document.dart; focused model tests. Root owns structured-document projection/export changes.

Interface: BlockLinkedDatabase.format = personal-ink-linked-database-1; create({required String noteId, required DatabaseView view}); fromJson(Map<String,dynamic>); noteId/view getters; copyWith({DatabaseView? view}); toJson(). Block type linkedDatabase stores linkedDatabaseData. BlockPageBlock.linkedDatabase getter is nullable for opaque future formats; factory createLinkedDatabase({required String noteId, required DatabaseView view, String text = ''}); copyWith supports linkedDatabase. Keep raw unknown fields. Existing page v1/2/3 compatibility and inline version floor remain unchanged unless a concrete writer hazard requires an explicit design correction.

- [x] Write focused model/unknown-format/roundtrip tests first; root observes RED.
- [x] Implement strict known-format decoding, stable identity, copy/convert/Markdown reference behavior; root observes GREEN.

## Task 2 — Guarded linked source sessions

Ownership: storage worker only: lib/pages/workspace/workspace_controller.dart; new lib/data/vault/linked_database_session.dart; focused controller tests.

Interface: LinkedDatabaseSession exposes NoteSession owner/target, current WorkspaceDatabase database, String revisionId, bool isClosed and close(). WorkspaceController.openLinkedDatabase(String noteId,{required NoteSession owner}); saveLinkedDatabase(LinkedDatabaseSession link,WorkspaceDatabase database,{Map<String,Uint8List> mediaFiles=const{}}); readLinkedDatabaseRowMedia(LinkedDatabaseSession link,String rowId,BlockPageMedia media). The owner remains the active page. The detached target must never become active or overwrite source views with an instance-local view. Reuse the controller's serialization, media preparation and guarded prepared-save behavior. Expose any unavoidable interface correction to root before dependent code is written.

- [x] Write real repository tests: shared-source edits, unchanged source views, stale heads/deletion, closed owner/repository switch, missing/kind/conflict rejection, retry/media preservation; root observes RED.
- [x] Implement source guards and side-session lifecycle without relaxing ordinary active-session guards; root observes GREEN.

## Task 3 — Independent view in existing DB editor

Ownership: DB UI worker only: lib/pages/workspace/database_editor.dart and a focused new test file.

Interface: add optional DatabaseView? viewOverride, ValueChanged<DatabaseView>? onViewOverrideChanged, bool embedded=false. Override mode uses that view for all seven projections and settings. Changing view/type/filter/sort/group/visible/config calls the local-view callback, never a source save. Row/schema/media actions keep the real original database views. embedded mode hides the document-back button and keeps an accessible compact header. Existing standalone behavior remains unchanged. No separate simplified database implementation.

- [x] Write widget tests first for local filter/view changes, actual row write, source-view preservation and 320px layout; root observes RED.
- [x] Implement override mode and preserve asynchronous save/row-body/dirty/busy behavior; root observes GREEN.

## Task 4 — Page insertion, live block, navigation and end-to-end integration

Ownership: root: new linked_database_block.dart/access callbacks; block_page_editor.dart; study_workspace.dart; structured document text and portable export projection; focused integration tests and guides/history.

- [x] Add DB choices and linked-block insertion to the existing block menu. Pick a source and copy its initial view into the block's local definition.
- [x] Render the original DatabaseEditor in a bounded inline region, using guarded sessions, existing Rust query/actions and original media ownership.
- [x] Track child editor dirty/busy/save states. Flush on save/back/open-note; preserve failed drafts and prevent removal/undo while a child has pending changes.
- [x] Verify two pages referencing one DB, page/view persistence, row/media persistence, rename/reopen, unavailable sources, retry, stale/repository transitions and 320px interactions.
- [x] Run relevant model/UI/controller/MCP/projection regressions, actual Rust DLL-backed DB-query integration and analysis. Broaden tests only for new failures/risks. Record actual results; package a later candidate only after its source-bound verification.

Root verification: full Flutter2010PASS/108skip/0FAIL; final Study menu2PASS and analysis0 after removing one unused test import. Runtime source697/31280725… stayed unchanged across that import cleanup; previous test bytes were exactly reconstructed and hashed. Actual Rust DLL11 and SDK stdio2 passed. The source-view map-order guard and query-filtered source picker failures were reproduced before fixes. Raw failures and scope-bound evidence are retained in build/validation/linked-databases1/checkpoint1.json. This feature is source-only; current Android64 and Windows62 packages do not include it. Device, standalone GUI, real two-device Drive and external LLM acceptance remain open, as does the full product goal.
