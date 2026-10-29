# Android·Windows·Drive Implementation Plan

> For agentic workers: use superpowers:subagent-driven-development or superpowers:executing-plans task-by-task. Checkboxes track actual results. User instructions prohibit commit/push without an explicit request.

**Goal:** Galaxy Tab S9+ PDF 필기 → Windows Markdown 정리 → Drive 자동 동기화 MVP.

**Architecture:** Saber 고정 커밋 편집기를 유지한 검증판에 완전한 로컬 snapshot, 고정 ID, 새 Drive 동기화를 붙인다. 로컬 저장·원격 전송·UI를 분리한다.

**Tech Stack:** Flutter/Dart, Saber `55eec16ad6f858bc68b7c229e497c5ed44d7c5fd`, BSON/첨부, Markdown 원문, 불변 파일 저장소와 재구축 인덱스, Drive API v3와 플랫폼별 OAuth다. SQLite는 데이터량 실측 뒤 캐시로 검토한다.

**Spec:** [MVP 설계](mvp-design.md), [Saber 소스 검토](saber-reuse-review.md), [StarNote 조사](starnote-investigation.md), [Obsidian 조사](obsidian-investigation.md). 사용자가 분석 반영과 개발 시작을 승인했다. 아래 완료 표시는 실제 시험 결과로만 갱신한다.

## 실행 현황 — 2026-10-23

- 개발은 `codex/mvp-foundation`에서 기존 미커밋 문서를 보존하며 진행했다. 2026-10-30 사용자가 현재 개발 변경을 `main`에 commit/push하도록 승인했다. 공개 범위는 앱 소스·문서·공개 시험 자료이며 APK·ZIP·계정 설정은 로컬에 유지한다.
- [확인] Saber 고정 소스의 Android/Windows·편집기·자산·시험을 도입했고 Nextcloud 자동 연결 및 upstream 전송 경계를 분리했다. 독립 격리 검토와 시험 3개를 통과했다.
- [확인] portable Flutter 3.47.7/Dart 3.13.5, JDK 25, Android SDK 37/build-tools 37/NDK 29 설치·실행. 전역 PATH·Codex 설정은 변경하지 않았다.
- [확인] 순수 Dart 저장/백업/Drive 시험 **51개**(10월 22일, 이후 패키지 미변경), 최신 기본 Flutter 시험 **237개 통과/105개 명시적 skip**, 전체 분석 문제 0, Android ARM64 debug APK 빌드·서명 및 Windows Release 빌드 성공. 이것은 실제 계정·실기기 왕복 결과가 아니다.
- [확인] 통합 검토의 편집/전환/종료 경합, Windows watcher/archive handle, 초기 오류 화면 종료 문제를 수정하고 재검토를 통과했다. 기존 upstream 전용 검사는 opt-in으로 보존했다. 상세 결과와 APK 식별자는 [검증 기록](mvp-validation.md)에 남긴다.
- [확인] Build Tools 2022 17.14.42·Windows SDK 10.0.26100.0·ATL 준비, C++ `/utf-8` 추가, 제거된 Android startup provider 수정. 새 Cloud 프로젝트의 Drive API·3종 OAuth client·External Testing·본인 테스트 사용자와 세 범위를 등록하고 공개 ID를 두 빌드에 포함했다.
- 미검증: 앱의 실제 Google 로그인/권한 동의·Drive 계정 왕복, S9+ 펜/PDF 좌표·종료 복구, Windows 네이티브 실행 수용 시험. Desktop secret은 필요하면 본인이 앱에서 입력한다.

현재 구현 경계는 아래 예상 파일보다 `packages/ink_vault_core`의 순수 Dart 저장·Drive 모듈과 Flutter 어댑터로 나눈다. P0–P5의 수용 기준은 그대로 유지한다. 한 작업의 단위시험 통과를 단계 전체 완료로 표시하지 않는다.

## Global Constraints

- 공개 저장소와 개인 vault/PDF/백업/APK/키를 분리하고 합성 자료로 검증한다.
- 명시 요청 전 commit/push/배포/개인자료 업로드를 하지 않는다. 실제 OAuth 계정 동의는 사용자가 수행한다.
- 조사 upstream은 위 SHA, Dart `^3.13.0`, Flutter `>=3.47.0`, Flutter submodule `abaf9c523780a608bd46686fd5e53740a07077f8`이다. SDK/lock 재현부터 확인한다.
- ID는 경로/제목과 독립한다. 시각 기반 승자·불완전 세대 활성화·충돌 사본 자동 폐기를 하지 않는다.
- StarNote 분석은 별도 조사이며 앱 개발의 선행 조건이 아니다. AI/OCR/그래프/iOS/실시간 공동 편집은 후속이다.
- 검증판은 GPL과 고지를 유지해 구현한다. 최종 제품 채택·외부 배포는 품질 gate와 배포 감사 뒤 판단한다. E2E 후순위·기기별 편집 역할 제한은 설계 선택이며 새 요구가 생기면 변경한다.

## Review Focus

1. PDF 회전/CropBox/혼합 크기에서 필기 위치 유지(P1/P4).
2. 저장/발행 직전 종료, 편집 중 원격 수신, 응답 유실 후 재시도(P1/P3).
3. 시계 차이·동시 수정·노트 삭제 대 자식 객체 오프라인 수정 보존(P3).
4. 인증 취소·권한/용량 부족·change token 무효화(P2/P3).
5. Markdown HTML/URL·손상 백업이 원본/현재 vault에 미치는 영향(P4/P5).

## 예정 파일 구조

upstream의 lib/packages/test/android/windows 구조에 다음 경계를 둔다.

```text
packages/ink_vault_core/lib/{ink_vault_core,drive}.dart
packages/ink_vault_core/lib/src/{repository,revision,backup}.dart
packages/ink_vault_core/lib/src/drive/
lib/data/vault/  lib/data/drive/drive_auth.dart
lib/pages/workspace/{study_workspace,markdown_editor}.dart
test/vault/  test/drive/  test/workspace/
integration_test/android_windows_flow_test.dart
```

### P0 — Saber 검증판과 채택 판정

**Files:** 도입할 upstream pubspec/lock, Android signing, Windows 사전 패치, main/flavor, 플랫폼 ID/아이콘. 새 `docs/upstream-provenance.md`, LICENSE/고지 목록은 실제 통합 시 확정한다.

**Interfaces:** 이후 단계가 소비할 고정 소스/lock과 Android·Windows에서 실행되는 편집기를 산출한다.

- [x] SDK·Android 도구·Windows C++ 도구의 기존 설치와 필요한 버전/경로를 기록한다. 전역 설정을 임의 변경하지 않는다.
- [ ] 직접/전이/네이티브/자산 라이선스와 출처·수정·고지를 확인한다. 앱 이름/ID/저장소/개발 서명을 독립시킨다. upstream 개인 vault를 열지 않는다.
- [x] Nextcloud 자동 연결/업로드와 upstream 서비스/업데이트 전송을 분리하고 telemetry는 명시 선택 전 전송하지 않는다. Android debug signing·Windows 사전 패치를 반영한다.
- [x] `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build apk --debug`, `flutter build windows --debug`를 실행하고 종료코드/실패를 남긴다. Windows 실패와 초기 전체 시험 실패도 검증 기록에 포함한다.
- [ ] S9+ 실제 펜·OS를 기록하고 합성 PDF에서 압력·손바닥·줌·undo/redo·저장/Windows 재열기를 비교한다.

**Gate:** 두 플랫폼 실행과 필기/PDF 가능성을 확인한다. 핵심 손실/좌표 오류가 두 차례 원인별 수정·재검증 후 남거나 코어 전면 재작성이 필요하면 독립 Flutter와 비용을 다시 비교한다.

### P1 — 고정 ID와 완전한 로컬 저장

**Files:** `packages/ink_vault_core/lib/src/{revision,repository}.dart`, `lib/data/vault/{saber_ink_adapter,workspace_store}.dart`; 수정 `lib/data/editor/page.dart`, `editor_core_info.dart`, `lib/pages/editor/editor.dart`, `lib/data/file_manager/file_manager.dart`; 패키지 `test/repository_test.dart`, 앱 `test/vault/`.

**Interfaces:** `SaberInkAdapter.capture`는 EditorCoreInfo에서 native 본문과 논리 asset 이름→bytes를 캡처한다. `NoteRepository.commit`은 entity/kind/files/parentRevisionIds로 durable revision을 발행하고 `heads`/`readFiles`가 완전 세대를 연다. `NoteSession`이 노트별 편집 부모를 유지한다. 해시는 저장소가 계산한다.

- [ ] 먼저 제목/페이지 재배치 후 ID, PDF 원본 해시, 본문/첨부 저장 실패 후 기존 세대, 인덱스 재구성 시험을 작성해 실패를 확인한다.
- [x] 페이지 ID 직렬화·문서별 저장 직렬화·임시 세대 검증/발행을 구현한다. 기존 watcher가 작업본을 원격 enqueue하지 않게 한다.
- [x] `flutter test test/vault`, `flutter analyze` 통과를 확인한다. 최종 전체 기본 시험에도 포함했다.
- [ ] 회전 0/90/180/270도·CropBox·혼합 크기와 합성 100페이지/약 50MB PDF로 저장·종료·Windows 재열기를 시험한다.

**Gate:** 저장 완료로 표시한 획을 보존하고 직전 완전 세대를 복구한다. 전송은 작업 파일 대신 이 리비전/blob 경계를 소비한다.

### P2 — 두 기기 Drive 인증·전송

**Files:** `lib/data/drive/{drive_auth,oauth_flow,drive_connection}.dart`, `lib/components/drive/drive_panel.dart`, `packages/ink_vault_core/lib/src/drive/drive_remote_store.dart`; 패키지 `test/drive/remote_store_test.dart`, 앱 `test/drive/`; [OAuth 설정](drive-setup.md).

**Interfaces:** `putBlob(hash, bytes, intentFileId)`, `publishRevision(record, intentFileId)`, `readBlob(fileId)`, `readChanges(token)`은 fileId·재개 상태·다음 token을 명시한다. auth는 token을 로그/화면에 내놓지 않고 만료/취소 상태를 전달한다.

- [ ] fake HTTP로 응답 유실 후 같은 ID 재시도, 재개 업로드, 401/403/429/5xx, 인증 취소/secure storage 실패 시험을 먼저 작성한다.
- [ ] 같은 Cloud 프로젝트의 플랫폼 client와 drive.file로 Android의 한 vault를 Windows가 접근하는지 실증한다. 외부 OAuth 테스트 모드의 refresh token 수명/재로그인도 확인한다.
- [ ] 플랫폼별 인증·보안 저장·전송을 구현한다. 실제 동의는 사용자가 하고 별도 시험 Drive 폴더에는 합성 자료만 쓴다.
- [ ] 패키지에서 `dart test test/drive`, 앱에서 `flutter test test/drive`를 확인하고 실제 두 기기의 전송/수신 해시를 확인한다.

**Gate:** 같은 vault 접근과 blob 재사용이 확인된다. 여기까지로 자동 동기화 완료는 아니다.

### P3 — 자동 동기화·충돌·삭제

**Files:** `packages/ink_vault_core/lib/src/drive/sync_coordinator.dart`, `lib/data/drive/drive_background.dart`; main·Repository listener·Nextcloud enqueue 접점; 패키지 `test/drive/sync_coordinator_test.dart`, 앱 `test/drive/`와 `test/workspace/`.

**Interfaces:** `SyncCoordinator.syncOnce()`는 durable queue를 진행하고 SyncStatus를 방출한다. parentRevisionIds의 ancestry로 head를 판단하고 해결 리비전은 충돌 head를 부모로 삼는다. 노트 tombstone의 baseRefs는 자식 객체 head를 관측한 범위다. 열린 편집 세션은 baseHeads를 고정한다.

- [ ] 먼저 두 fake device로 같은 부모 동시 수정, 시계 ±24시간, 노트 삭제 대 ink/Markdown 수정·새 자식 생성, 응답 유실, manifest 먼저 관측, blob 누락, 무효 token/재시작 시험을 작성한다.
- [x] dirty 편집 중 원격 수신이 작업본을 덮지 않고, 다음 저장이 편집 시작 당시 baseHeads를 부모로 삼아 분기를 보존하는 시험을 추가한다.
- [x] blob-first/manifest-last, 완전 세대 활성화, 지속 누락 큐/cursor, 충돌/tombstone·자식 범위 판정을 구현한다. 공유 head 덮어쓰기·시각 기반 승자를 넣지 않는다.
- [ ] 저장 debounce·실행/복귀/재접속·실행 중 polling·Android WorkManager를 연결한다. Windows 종료 상태 작업은 추가하지 않는다.
- [ ] `flutter test test/drive`, `flutter analyze`를 확인하고 오래된 기기의 재합류/삭제 충돌을 시험한다.
- [ ] S9+→중단→재접속→Windows 자동 반영을 실행한다. 최초 업로드 이후 작은 변경 30초 목표는 제안값으로 측정하고 큰 파일은 따로 기록한다.

**Gate:** 수동 새로고침 없이 전달되고 실패/충돌이 완료와 구분된다. 누락·조용한 덮어쓰기·불완전 PDF/필기 조합은 실패다.

### P4 — Windows Markdown workspace

**Files:** 새 `lib/pages/workspace/study_workspace.dart`, `markdown_editor.dart`; 수정 routes/home 목록; 시험 `test/workspace/markdown_editor_test.dart`, `page_link_test.dart`.

**Interfaces:** Repository의 noteId/pageId/Markdown을 소비하고 `openPage(noteId, pageId)`로 PDF 위치를 연다. Markdown은 ownerNoteId를 갖는 별도 entity revision이며 Android는 읽기 전용이다.

- [ ] 분할 화면·Markdown/수식 미리보기·본문 검색·제목/페이지 재배치 후 링크 유지 시험을 먼저 작성한다. HTML/스크립트·위험 URL 미실행도 포함한다.
- [x] 원문·미리보기·문서/페이지 링크·검색을 구현한다. Quill Delta를 Markdown 원문으로 간주하지 않는다. OS 딥링크 등록은 후속이며 앱 안에서 링크를 해석한다.
- [ ] `flutter test test/workspace`를 확인하고 Windows 정리→Android 자동 수신을 실행한다.

**Gate:** 필기를 보며 정리할 수 있고 Markdown 저장이 PDF/ink hash를 바꾸지 않는다.

### P5 — 백업·복원과 MVP 판정

**Files:** `packages/ink_vault_core/lib/src/backup.dart`, 패키지 `test/backup_test.dart`; 로컬 내보내기/복원 UI `study_workspace.dart`. 기기 통합 시험은 후속 `integration_test/`이며 결과는 [검증 기록](mvp-validation.md)과 history에 기록한다.

**Interfaces:** `BackupService.exportSnapshot(repository)`는 완전 리비전·blob을 버전 JSON/base64로 묶는다. `restoreToEmpty(bytes, destination)`는 빈 대상으로 새 vaultId를 만들고 내부 noteId/pageId를 보존한다. token/전송 상태는 포함하지 않는다.

- [ ] 정상/첨부 누락/해시 불일치/미지원 schema/중간 실패/위험 archive 경로 시험을 먼저 작성한다. 손상 입력이 현재 vault를 바꾸면 실패다.
- [ ] 전체 내보내기/빈 저장소 복원·별도 Drive 스냅샷을 구현한다. token/계정 설정은 백업하지 않는다.
- [ ] `flutter test`, `flutter analyze`, 두 debug build 후 실제 오프라인 필기→중단/재시도→Windows 정리→Android 열람→빈 기기 복원을 실행한다.
- [ ] OS·펜·앱/SDK·표본 크기·시간·원본/복원 해시·실패/미검증 범위를 기록한다. 표본 통과를 모든 PDF/기기 보장으로 확대하지 않는다.

**MVP 완료 조건:** P0–P5를 실제 결과로 통과하고 사용자가 두 기기 흐름을 수용한 상태다. 기반 코드·기본 시험·Android 빌드·통합 검토를 통과했으나 Windows 실행·실제 OAuth·S9+ 수용 gate는 남아 있다. 기존 합의/구현을 처음부터 다시 시작하지 말고 남은 기기·계정 수용 시험을 이어간다.

StarNote 정적 분석은 [별도 기록](starnote-investigation.md)으로 관리한다. .note 파싱·편집·왕복은 미검증이다.
