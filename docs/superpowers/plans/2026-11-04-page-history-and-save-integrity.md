# Page History and Save Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax. 사용자 지시에 따라 질문 없이 진행하며 commit/push/공개는 하지 않는다.

**Goal:** 블록 페이지의 과거 판본을 현재 저장본과 비교하고 새 판본으로 복원하며 Android Office 재시도와 Word 사진 보존의 확인된 저장 경계를 보강한다.

**Architecture:** 기존 불변 revision DAG·단일 writer·PreparedCommit을 재사용한다. 과거 열람은 session 부모를 바꾸지 않고 복원은 비교 당시의 현재 head가 그대로인 경우에만 조건부 공개한다. 외부 서비스·새 저장 형식 없이 전체 파일과 unknown JSON을 보존한다.

**Tech Stack:** Flutter/Dart, existing ink_vault_core repository, Python UNO Windows worker, Android embedded Office bridge.

## Ownership and execution

- page_history_domain: new `lib/data/vault/block_page_history.dart`, `workspace_store.dart`, new history/restore domain tests.
- root: `workspace_controller.dart`, `study_workspace.dart`, new history sheet/UI/integration tests and docs.
- android_office_retry_fix: `office_document_store.dart`, `office_workspace.dart`, focused Android fixture/store retry tests.
- word_source_baseline_fix: Word Python layout/images/worker and focused image-save tests.
- Root alone executes all Flutter/Python/Native/Cargo/build checks; one Native Office job at a time. All workers preserve each other's edits. Build48 APK/ZIP remain current until a later verified promotion.

## Task 1 — Read-only page history and meaningful block comparison

- [x] Domain RED: owned same-vault/entity/kind revisions; no inferred dates; graph-based ordering; preview performs no writes or parent changes.
- [x] Compare fixed block IDs for add/delete/move/type/text/check/fold/link/unknown JSON changes, including page-level unknown metadata.
- [x] Add Study page history action and responsive read-only selection/current-versus-past comparison. Loading/error/stale-scope states retain the open editor.
- [x] UI RED→GREEN at320px and real Study A save→B save→compare A/B without modifying either source.

## Task 2 — Restore as a new immutable revision

- [x] Domain RED: full file map/baseRefs, old snapshots and separate Markdown retained; foreign/deleted/wrong-owner revisions rejected.
- [x] Use session serialized PreparedCommit publication with expected current head; refuse remote changes/ambiguous heads, reuse own exact prepared result after ambiguous success. Current metadata and complete ancestor-folder guards also pass four new race/liveness regressions.
- [x] Controller validates active session/repository scope and serializes restoration; Study saves dirty editor before capture and prevents editing during restore. Reopen editor only after successful commit.
- [x] Integration RED→GREEN: restore A from B→back→reopen A; preserve B/attachments/unknown fields and Markdown; retry/stale head/session switch checks.

## Task 3 — Android Office response-loss retry

- [x] Actual repository RED: commit then throw; retry currently creates sibling revision/binding.
- [x] Once-prepared edition token captures exact binding/PreparedCommit and scope; retain in pending native result, preserve old Windows/MCP caller semantics and branch policy.
- [x] Actual repository and native-fixture UI retry GREEN; source/PDF/annotation binding remain single and original bytes unchanged. This is not Android JNI execution evidence.

## Task 4 — Word source picture baseline and final-close cleanup

- [x] Root RED:9 tests/5 failures for supported width/margin/payload damage, complete Frame+inventory removal and final-close failed private output cleanup.
- [x] Bind image source expectation to native identity/payload/author format/owner before text operations; permit only explicit verified imageReplace payload updates and legitimate moving text anchor offsets.
- [x] Place final canonical close inside success/failure cleanup boundary. Preserve original errors and unknown-source fallback.
- [x] Python142PASS and fresh native text/image/geometry regressions; current37 modules match native proof hashes. Keep14/15 saved-format limitation and unknown Frame support boundary explicit.

## Integration gate

- [x] Root reviews worker diffs and checks current source state; relevant suites, full1009PASS/108skip/0FAIL·analysis0, build49 Windows/Android, packaged15+DLL9 and45 integrity gates pass.
- [x] Update history/HANDOFF/validation with exact scopes and logs. New REA reuse restored41 canonical records and re-read actual shipped Collabora selected-source summary; partial static analysis is not Android runtime proof.
- [ ] Full requested Android/Windows/Drive/Office/Obsidian/Notion/MCP goal remains active until requirement-by-requirement end-state evidence exists.
