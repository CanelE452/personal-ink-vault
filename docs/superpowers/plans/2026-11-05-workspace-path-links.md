# 문서·폴더 경로 변경의 링크 보존 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. 사용자 지시에 따라 질문 없이 계속한다. root만 명령·시험·native 실행을 소유하며 commit/push/공개는 하지 않는다.

**Goal:** 문서 이동, 폴더 이름 변경·이동, 휴지통/복원 뒤에도 기존 Markdown·Wiki·구조화 문서 링크가 원래 문서 UUID와 anchor/표시를 유지하게 한다.

**Architecture:** 기존 KnowledgeCatalog·Rust resolver·raw token rewrite·prepared conditional publication을 확장한다. 이동한 source의 outbound와 경로가 바뀌는 target의 inbound를 변경 전 catalog에서 고정 ID로 바꾸고 메타데이터를 마지막에 공개한다. 기존 본문/첨부·미지원 JSON·원래 판본을 보존하고 권한/전체 head 집합을 매 단계 재검사한다.

**Tech Stack:** 기존 Flutter3.47.7/Dart3.13.5, Rust1.99.1 C ABI, immutable repository v2. 새 dependency/서버/전역 설정은 없다.

**Spec:** [요구사항 R4/R6/R7/R8](../../requirements.md), [확대 설계](../../library-workspace-design.md), [Obsidian 조사](../../obsidian-investigation.md). 이 작업은 전체 Office/Obsidian/Notion 목표의 일부이며 전체 완료를 뜻하지 않는다.

## Global Constraints

- build53/code136053 canonical APK/ZIP는 다음 빌드·패키지 gate 전까지 유지한다. 전체 dirty main 작업공간·기존 실패 근거를 보존한다.
- 사용자가 main과 질문 없는 구현을 이미 지정했다. 기존 문서 체계와 실제 작업 폴더에서 진행하며 새 worktree/commit을 만들지 않는다.
- 경로·제목을 ID로 쓰지 않는다. 코드/주석/unknown 필드의 닮은 문자열을 무작정 바꾸지 않는다.
- UI와 MCP는 같은 store API를 사용한다. MCP는 각 prepared publish 직전 repository/context 쓰기 권한을 검사한다.
- 별도 실제 PPT 표 관측은 병행 연구이며 이 링크 작업의 완료/제품 구현으로 합산하지 않는다. native Office 실행은 항상 root가 하나씩 소유한다.

## Review Focus

1. 옮긴 source의 상대 링크가 새 폴더의 동명이문서로 바뀌지 않아야 한다. inbound만 검사하지 않는다.
2. subtree 안팎의 양방향 링크, emoji·퍼센트 anchor·Wiki alias·Markdown title과 첨부 bytes를 보존한다.
3. 미해결 경로/충돌/ambiguous target, unknown structured 문맥, 권한 철회는 metadata 변경 전에 거부한다.
4. source 변환 일부 공개 후 응답 유실은 동일 prepared token으로 이어가고 외부 head 변경은 덮지 않는다.
5. 휴지통의 관측 baseRefs가 새 링크 판본을 포함해야 한다. 이미 삭제된 원문/기존 tombstone·복원 의미를 손상하지 않는다.

## Task 1: actual 조사와 결함 RED

**Files:** 기존 `build/research/obsidian/obsidian-1.14.4.asar`와 관련 REA Evidence; 새 `test/vault/knowledge_path_change_test.dart`.

- [x] 현재 source를 추적했다. note rename만 `renameKnowledgeNote`; moveNote·rename/moveFolder·setDeleted는 metadata만 변경한다. KnowledgeCatalog paths는 현재 폴더에서 재계산된다. 이는 실행 전 결함 후보이며 실제 RED로 확정한다.
- [x] 고정 Obsidian ASAR identity와 선택 app.js REA 관측을 보존하고 rename/link update 관련 실제 byte range·unknown을 기록했다. 정적 관측을 실행 증거로 쓰지 않는다.
- [x] root가 실제 Rust DLL 기반 resolver와 repository fixture로 문서 이동·폴더 rename/move·휴지통 후 경로 재사용의 RED를 실행했다. 최소 `Course/A.md -> B.md`, `Other/B.md` 동명이문서와 외부 `Course/B.md#Heading`를 포함한다.

## Task 2: Rust 단일 pass 대상 집합

**Files:** `packages/ink_vault_native/src/knowledge.rs`, `packages/ink_vault_native/tests/knowledge_links.rs`.

**Interface:** 기존 `rewrite_note_links`는 `targetId: UUID` 또는 `targetIds: UUID[]` 중 정확히 하나를 받는다. targetIds는 중복 없는 known canonical UUID, 최대10000개이고 []는 valid no-change다. 기존 targetId 결과는 그대로다. source/catalog에서 한 번 resolve하며 각 unsupported row는 실제 targetId를 포함한다.

- [x] worker가 multi-target/UTF16/anchor/alias/title/unknown·duplicate·xor·empty·max bound RED를 썼다. root `cargo test --manifest-path packages/ink_vault_native/Cargo.toml --test knowledge_links`로 실제8FAIL을 확인했다.
- [x] root RED 후 selected set과 Change별 target identity를 구현했다. unresolved/ambiguous/stable·code/comment/HTML 정책은 유지하며 per-target parse 반복은 도입하지 않았다.
- [x] root 전체 Rust101PASS·formatter/clippy exit0와 Windows DLL 빌드를 확인했다. Android ARM64 release SO도 같은 소스로 다시 빌드했다(`native-android-build1.txt`, exit0/4.86초). 설치 앱 전체 빌드·기기 실행은 별도 gate다.

## Task 3: 공통 경로 변경 coordinator와 domain

### 조건부 historical branch 기반

`packages/ink_vault_core/lib/src/repository.dart`의 `commitPreparedIfHeads`에 opt-in `allowHistoricalParents=false`를 추가했다. 기본 경로는 기존과 같고 true는 전체 revision snapshot·유효한 nonempty same-entity/kind/owner parents와 현재 captured heads를 요구한다. 정확한 replay heads는 `(captured write heads − prepared direct parents) ∪ {prepared revision}`이다. 새 remote branch/descendant·다른 entity·권한 철회는 인정하지 않는다.

[확인] 새9개 core 회귀는 첫 fixture의 Dart baseclass 컴파일 오류를 수정한 뒤 기존 default1PASS/신규API미구현8FAIL이었다. 제품 구현 후 전체 core159PASS/0FAIL(24초)을 확인했다. 기존 동시 폴더 이동 branch 기대를 바꾸지 않았으며 새 opt-in은 전체 source/head guard를 생략하는 우회가 아니다.

**Files:** `lib/data/vault/knowledge_rename.dart`, `workspace_store.dart`, `library_store.dart`; 새 `test/vault/knowledge_path_change_test.dart`, 기존 `knowledge_rename_test.dart`, `library_store_test.dart`.

**Interfaces:** 기존 `renameKnowledgeNote`를 유지한다. 같은 repository coordinator가 note move·folder rename/move의 exact operation identity, captured heads/revisions, 준비된 본문 변경들과 마지막 metadata commit을 소유한다. store의 `moveNote`, folder `renameFolder/moveFolder`에 optional `void Function()? requireWrite`를 추가한다. LibraryStore의 native invoke는 WorkspaceStore와 같은 기본 factory/명시적 injection을 사용한다.

- [x] note 이동 시 affected target={note}, moved sources={note}; folder rename/move 시 captured descendant note IDs가 양쪽이다. moved source에는 catalog 전체 known IDs, 다른 source에는 affected target IDs를 Rust에 전달한다.
- [x] raw Markdown과 기존 지원 structured 경로만 바꾸고 extra files·unknown JSON을 보존한다. 빈 폴더/링크 없는 이동에 불필요한 native 의존을 강제하지 않는다. no-op는 불필요한 판본을 쓰지 않는다.
- [x] 목적지·captured metadata/head·부모 cycle·deletion conflict·path ambiguity를 준비/최종 게시 양쪽에서 검사한다. capture 뒤 새 head 경합은 거부한다. 기존의 유효한 older metadata parent를 사용한 동시 branch 생성 계약은 보존하며 임의 timestamp 선택으로 대체하지 않는다.
- [x] body 변경→마지막 metadata 순서를 prepared conditional publish로 구현한다. response loss 시 기존 plan을 재사용하며 다른 작업을 pending plan에 섞지 않는다. 원래 rename 회귀/삭제된 note rename 호환을 유지한다.
- [x] root가 source/target 이동, 중첩 folder 양방향/동명, structured page/canvas/DB, aliases/anchor/Unicode, unknown/attachment bytes, 실패 재시도·stale heads·권한 철회 회귀를 실행한다.

## Task 4: 휴지통·복원 의미

**Files:** 위 coordinator/store와 `test/vault/knowledge_path_change_test.dart`, 기존 삭제/복원 회귀.

- [x] trash 전 active source/target 연결을 고정하고 같은 경로의 새 문서가 옛 링크를 빼앗지 못하는 RED를 실행한다. 삭제된 source 원문과 이전 판본은 자동 재해석하지 않는다.
- [x] final tombstone의 observed baseRefs는 해당 subtree/소유 entity의 링크 정규화 후 예상 heads를 사용한다. 다른 entity의 refs를 섞지 않는다.
- [x] restore는 현재 deleted metadata·동시 자식 변경·충돌을 검사하고 기존 baseRefs 의미를 유지한다. UUID 링크를 새 경로의 문서로 바꾸지 않는다. 이 부분의 근거가 없으면 완료 체크하지 않고 계속 구현한다.

## Task 5: UI/MCP 통합과 최종 수용

**Files:** `lib/data/mcp/vault_mcp_service.dart`, 필요한 `study_workspace.dart`/controller 연결; `test/mcp/access_permission_race_test.dart`, 새/기존 workspace navigation 테스트.

- [x] MCP document_action move/trash/restore에도 rename과 같은 repository+write callback을 전달한다. folder 액션이 기존 MCP에 없으면 새 공개 도구를 임의로 추가하지 않고 UI 경로부터 공유 domain을 사용한다.
- [x] MCP `document_action` rename/move/trash/restore는 generic v1 started와 분리한 v2 prepared 영수증을 사용한다. domain이 공개하는 `PreparedKnowledgeChange`/async `onPrepared`/resume API로 첫 canonical body publish 전에 exact steps와 recovery files·초기 heads/ids를 내구 저장한다. root/vault/device/format/request digest/action/원본 metadata와 final metadata/owner·변경 필드의 결합을 검증하며 planDigest만으로 요청 권한을 대신하지 않는다.
- [x] 재시작은 canonical bytes가 맞는 연속 owned prefix만 인정해 heads/ids/next를 복구한다. 새 외부 revision/부모/source 교체·nofollow 링크·손상/누락·중간 prefix 구멍은 거부한다. completed는 실제 canonical manifests/files를 다시 검사하고 같은 요청 결과를 반환한다. 구형 진짜 v1 completed 호환·v1 started unknown은 유지하며 단순 version downgrade로 v2 우회를 허용하지 않는다. 새 v2 started는 prepared 내구 기록 완료 전에 앱 publish가 불가능하다는 순서와 initial snapshot 불변을 모두 확인한 경우에만 다시 prepare할 수 있다.
- [x] UI 저장 중 branch/dirty 관리, 홈→이동/폴더변경→기존 링크열기→뒤로·재열기를 실제 repository/Rust로 검사한다. MCP 동일 요청 재시도와 최종 publish 전 권한 철회를 확인한다.
- [x] root가 focused→관련 회귀→전체 앱/분석·core/Rust·실제 DLL/stdio를 확인한다. 새로운 failure만 추가 broad 재실행의 근거로 삼는다.
- [x] 변경 소스 고정·fresh review 뒤 두 앱 새 빌드와 설치 bundle·서명/OAuth/native/guide 무결성 gate를 통과한 경우에만 canonical을 교체한다. S9/Drive/외부 LLM 실사용 미검증은 그대로 남긴다.
- [x] `_docs/history/2026-11-05.md`와 최신 인계·검증·계획에 actual Evidence/RED/GREEN/남은 범위를 기록한다. 전체 목표는 활성으로 유지한다.

## Rulings

- 기존 링크를 경로 변경 후 다시 추정하지 않고 변경 전에 UUID로 고정한다. 대상이 명확하지 않거나 안전한 원문 변환을 입증할 수 없으면 metadata를 먼저 바꾸지 않는다. 잘못 판단하면 일부 linked 이동을 거부할 수 있으나 기존 연결을 조용히 다른 문서로 바꾸는 것보다 복구 가능하다.
- body 일부가 이미 UUID로 공개된 뒤 실패해도 기존 경로가 살아 있으므로 연결을 보존한다. 마지막 metadata 공개와 그 응답 유실은 exact prepared token/heads로 재확인한다. 이 전략은 전 기기 원자적 transaction이나 모든 전원 손실의 exactly-once 보장이 아니다.
- 기존 `concurrent folder move branches are retained instead of timestamp selection` 기대는 바꾸지 않는다. 캡처된 실제 head 집합을 guard하면서 caller의 유효한 기존 parent를 보존한다. 링크 변환이 필요하고 원래 문맥을 확정할 수 없으면 먼저 거부하지만, 이미 UUID로 고정한 링크나 빈 문서의 유효한 concurrent metadata branch를 단지 오래된 입력이라는 이유로 없애지 않는다.
- prospective 경로 충돌은 이동한 대상의 inbound만으로 해결되지 않는다. 기존 목적지의 동명이문서를 가리키던 source도 보호한다. old/prospective catalog를 같은 Rust resolver로 비교해 해석이 달라질 원래 target을 추가 고정한다. logical UUID 기반 폴더의 기존 동명이문서·동시 branch 기능을 전면 금지하는 것으로 대체하지 않는다. restore도 되살아나는 subtree와 기존 namesake를 비교한다.

## 최종 수용 기록 — 2026-11-05

[확인] 경로/UI 집중129PASS, MCP47PASS, Office 재시도14PASS와 실제 Rust stdio 경로 재시작1PASS다. 전체 앱1319PASS/108skip/0FAIL·분석0, core159·Rust native101을 확인했다. Windows54/Android136054를 빌드하고 설치 SDK/native20·FFI9 및 최종 독립45개 검사를 통과한 뒤 canonical APK/ZIP/manifest를 승격했다. 소스613파일 SHA는 `8c03057784a2945af472e9b73633f72b0c40adffbcc4b90e8bc3d999235771ff`다. 겹치는 시험 수를 합산하지 않는다.

실제 근거는 `build/validation/workspace-path-links/path-build54-r1-canonical-artifacts.json`, 같은 prefix의 plan/built-proof/installed-sdk-binding/각 gate·exit·log와 [오늘 이력](../../../_docs/history/2026-11-05.md)이다. 실패한 최초 broad·설치 검사는 보존했다. 설치 첫 mutation 실패는 trace report 경로 fixture를 새 소유 디렉터리로만 옮긴 R1 clone에서 다시20개 전체 실행으로 확인했다.

이 계획의 로컬 구현·수용 범위만 완료했다. S9+/S Pen·Android JNI·두 기기 Drive·외부 LLM 실사용은 미검증이며 PPT 표·전체 Office/Obsidian/Notion 목표는 계속 진행 중이다. commit/push·공개 게시·전역 AI 설정 변경은 없다.
