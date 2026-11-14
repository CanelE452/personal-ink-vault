# Android Office 뒤로가기·사진 선택과 원본 미리보기 구현 계획

> **For agentic workers:** Use superpowers:subagent-driven-development for independent ownership. Root executes tests, REA, formatting and builds; workers do not run them.

**Goal:** 태블릿 Office 편집기의 뒤로가기가 열린 도구 화면부터 닫고, 사진 선택 취소·늦은 결과가 기존 문서 편집을 중단시키지 않게 한다. 사용자의 전체 Word/PPT·필기·Obsidian·Notion·Drive·MCP 목표를 유지한다.

**Architecture:** 기존 내장 LOActivity의 상태별 뒤로가기 정책을 공통 protected hook으로 보존하고 OfficeEditorActivity의 일반 편집 callback이 이를 호출한다. 자동 PDF 준비의 취소는 기존 subclass 경로를 유지한다. 사진 결과는 로컬 callback을 먼저 분리한 후 살아 있는 편집기에 한 번만 전달한다.

**Tech Stack:** 기존 Flutter/Dart·Android Java/Kotlin·고정 Collabora26.04.6.0-962·REA6.7.0/JADX0.7.1·기존 Windows UNO/Python.

**Spec:** [요구사항](../../requirements.md), [앱 확대 설계](../../library-workspace-design.md). 기존 build51 복구 기록·데이터 형식과 APK 서명을 보존한다.

## 변경 전 근거

- 이전 목표 턴은 build51의 실제 생성·로컬 승격·45개 검사로 진전했다. 현재 build/releases manifest는 Windows51/Android136051이며 전체1109PASS/108skip/0FAIL·분석0이다. 현재 하드웨어 연결이 없는 것은 전체 구현을 멈추는 장애로 취급하지 않는다.
- 현재 OfficeEditorActivity의 always-enabled callback이 super callback보다 나중에 등록돼 도구 패널·슬라이드쇼 상태와 관계없이 finishWithProgress로 간다. 고정된 원본 LOActivity는 fullscreen→slideshow→mobile wizard→editmode→finish 순서다. 원본의 !documentLoaded는 finishAndRemoveTask이므로 subclass callback만 지우면 Flutter task를 제거할 수 있다.
- 공식 APK의 onActivityResult를 실제 REA로 역컴파일했다. evidence `ev_df4be2ca2d1cab570cba3e5fd97aa2e1f07da958b7fe314a41364aa66e1af177`이며 Java body available/no fallback이다. 취소 결과500에서 callback null 검사가 없고, 성공 분기는 callback 뒤 field를 지운다. 현재 고정 소스와 같은 경계를 확인했다. onCreate는 `ev_60f069f4eed16f37ee707a8fd70b84d3299a3f45a380763a5f53d39c3fc41745`이며 parsed Java callback 등록을 별도 추적한다.
- Android 사진 삽입은 기존 WebView image chooser 경로가 있다. 이를 미구현으로 분류하지 않는다. Windows Word의 추가·이동·삭제는 현재 payload 교체와 달리 이미지 inventory/Frame/anchor 보존 계약까지 새로 필요하므로 별도 실제 native 관측을 먼저 진행한다.

## 소유와 제약

- Native worker: `android/office_engine/prepare_engine.py`, `OfficeEditorActivity.java`, 새 `test_interaction.py`. 테스트만 작성→root RED 확인→제품 구현 순서다.
- Word 관측 worker: 새 ignored `build/validation/office-word-fidelity/probe_word_picture_mutations.py` 한 파일. 합성 문서의 실제 삽입/이동/삭제·원본 저장/독립 재열기·Frame/owner/graphic SHA를 기록하며 제품 코드는 수정하지 않는다.
- Root: REA·모든 실행·리뷰·Android 컴파일·전체 회귀·빌드/설치 묶음·문서. 다른 작업자의 기존 변경을 되돌리지 않는다.
- 원본 미리보기 worker: 새 `office_original_preview.dart`와 component/integration 시험만 소유한다. Root가 `OfficeWorkspace`의 호출·명시적 read-only 변환·busy/late 결과 경계를 연결한다. 이미 PDF가 있으면 선택 판본의 첫 페이지를 보여주고, 없으면 사용자가 **원본 미리보기**를 눌렀을 때만 private 변환한다. 미리보기는 canonical revision/annotation을 생성하지 않는다. 기존 `PdfDocumentCache`·`PdfPageView`와 설치된 PDFium을 재사용한다.
- native FIFO·close-once·watchdog/timeout·기존 preview readonly·working journal·Drive/MCP/자료 형식·toolchain을 바꾸지 않는다. commit/push/공개 게시·전역 AI 설정을 하지 않는다.

## 실행 체크리스트

- [x] 정확한 generated helper와 parent/subclass callback bodies를 plain JDK harness에서 실행하는 RED 시험. nested back 우선순위, 문서 로드 전 안전 종료, 반복/종료 중 back, preview 취소를 포함한다.
- [x] null/취소/성공/늦은/중복/재진입 image callback 시험. 기존 export 취소 경로를 보존하고 두 실제 image result 분기를 helper에 연결한다.
- [x] 최소 제품 수정 후 새 interaction·기존 lifecycle/recovery 및 Android Java/Kotlin 컴파일. Java stub 시험·컴파일과 실제 S9+/JNI 실행을 구분한다.
- [x] 기존 Word 이미지 native 관측 패턴으로 합성 사진 추가·anchor 이동·삭제와 DOCX 독립 재열기를 조사한다. 실제 관측이 다음 구현 결정을 바꿔야 하며 기존 사진 교체 관측을 추가/이동/삭제 증거로 재사용하지 않는다.
- [x] 원본 탭의 선택 판본·PDF SHA·note/root에 결합한 첫 페이지 표시를 실제 PDFium 색 픽셀로 확인한다. 320px·판본 전환·loading 중 unmount·손상 PDF·원본 bytes/기록 불변, 명시적 변환의 취소/재시도·늦은 결과를 검증한다. 필기/주석 renderer나 commitEdited를 단순 보기 목적으로 호출하지 않는다.
- [x] fresh 리뷰에서 확인한 retained native preview output의 소유권을 lease로 명시한다. 반환 경로를 신뢰해 임의 폴더를 삭제하지 않고 이 호출이 만든 출력만 완료·실패·늦은 결과에서 해제한다. 실제 PDF 리소스 닫기와 원본·durable 편집 복구 보존 회귀를 함께 확인한다.
- [x] 리뷰·전체 회귀·새 APK/Windows 묶음이 실제 검증되기 전에는 기존 build51 설치 묶음을 유지한다. 전체 요구가 완성됐다고 표시하지 않는다.


## build52 최종 묶음

[확인] 전체1141PASS/108skip/0FAIL(321초)·분석0과 Windows52/Android136052, 새 설치 MCP/문서 엔진18PASS·DLL9PASS·최종45개 무결성 검사를 통과했다. 원본 첫 페이지 12개 실제 PDFium 시험과 lease 40개 집중 시험은 실제 기록/원본 보존·늦은 결과·리소스 종료를 검사한다. 홈 표지·MCP 호출자의 lease 종료 회귀11개와 고정 ZIP 시각 fixture 회귀28개도 통과했으며 foreign path prefix 기반 삭제는 제거했다. Word 사진 추가/삭제·객체 교체 이동은 별도 합성 관측으로 남기며 제품 API 구현으로 표시하지 않는다. plain JDK·Android 컴파일·APK 포함과 실제 S9+/JNI를 구분한다. 정확한 파일·해시·남은 범위는 [검증 기록](../../mvp-validation.md)을 따른다. 전체 목표는 계속 미완료다.
