# 페이지 미디어와 Android Office 관측 구현

기준: source654/909caed8…, 로컬 검증 묶음 build56/136056. 이 계획은 기존 전체 Office·Obsidian·Notion·Android/Windows·Drive·Rust·MCP 목표의 다음 구현 단계이며 전체 완료 범위를 줄이지 않는다. build56 증거와 파일은 보존한다. 사용자 지시에 따라 추가 질문 없이 구현·검증한다. commit/push·게시·전역 AI/Google 설정 변경은 하지 않는다.

## 목적과 설계 결정

페이지 안에서 이미지·첨부를 추가하고 본문과 함께 저장·재열기·이력 복원·Drive 전달하며 다른 LLM도 소유 미디어를 읽게 한다. Android Office는 기존 문서 세션에서 실제 native 관측을 얻는 경로를 추가해 이후 구조화 편집을 연결한다. native 표/셀 권위나 실제 기기 성공을 관측 없이 발행하지 않는다.

Ruling: 새 미디어 페이지는 version2와 루트 `blockMedia:{blockId:descriptor}` 등록부를 쓴다. — 구 build56의 page.json만 저장하는 writer가 binary를 잃지 못하게 형식 읽기를 거절하도록 하고, v1 unknown image 블록을 재해석하지 않기 위해서다. 비용은 구 앱에서 이 새 형식 페이지를 편집하지 못하는 것이다.

Ruling: 미디어는 같은 ink snapshot의 `page.json`과 `media/<SHA256>.<ext>`로 저장한다. 기존 opaque 파일과 사용하지 않는 이전 미디어도 보존한다. — PreparedCommit·Drive·이력의 기존 원자 공개와 undo를 재사용한다. 비용은 후속 수거 전까지 snapshot 참조가 늘어나는 것이다.

Ruling: 이미지 검증은 기존 PNG/JPEG 검증기의 20MiB/40MP를 재사용하고 첨부는64MiB, snapshot은128MiB로 제한한다. — 기존 앱에 있는 decode·길이·SHA 검증을 유지하고 선택/저장에서 무제한 메모리 할당을 피한다. 다른 형식·대용량 streaming도 전체 목표의 후속 범위다.

Ruling: Android는 `COKitDocument`의 실제 공개 read API와 기존 FIFO/preview 세션을 재사용한다. 전역 `COKit.executeScript`를 document 메서드로 취급하지 않는다. — 배포 헤더와 JavaScript의 request/response wire는 확인했지만 core의 JS-UNO 표/셀 binding은 실행 검증하지 못했다. 비용은 이번 native 관측을 최종 구조화 편집 완료로 표시할 수 없다는 것이다.

## 구현과 수용

1. 모델·snapshot: v1 unknown JSON과 파일을 보존한다. v2 등록부의 block 소유권·경로·SHA·길이·MIME·이미지 치수를 확인한다. 일반 저장에서2→1 강등, 누락/손상/다른 bytes 충돌을 거절한다. 명시적인 과거 snapshot 복원은 유지한다.
2. 편집기: 이미지·첨부 추가/교체/삭제, caption, 이동, undo/redo, 저장과 실패 재시도를 연결한다. picker/export도 busy에 반영하고 늦은 결과가 다른 문서에 들어가지 않게 한다. 원본 파일은 실행하지 않고 사용자가 선택한 경로로 저장한다. 미디어 저장 callback이 없는 DB 행 등에서는 바이너리 추가를 노출하지 않는다.
3. controller/Study: 선택 판본의 전체 snapshot과 추가 bytes를 같이 저장한다. 세션 교체·저장 실패에 draft와 원본을 보존한다. 재열기·과거 미디어 복원·두 disk repository 전달 검사를 한다. DB 행 미디어도 별도 저장 연결 전에는 dangling 등록부를 허용하지 않는다.
4. MCP: 문서·판본·블록 ID를 검증하는 소유 미디어 읽기 도구를 Rust schema와 Dart service에 연결한다. 이미지 표시와 원본 chunk 읽기를 구분하며 읽기 권한·소유권·길이/전달 예산을 확인한다. 전역 blob hash·임의 파일 경로·스크립트는 입력으로 받지 않는다. 수정은 기존 `update_document`의 판본/준비 저장을 사용하고 존재하지 않는 media 참조를 거절한다.
5. Android: native 관측 bytes는 표준 UTF-8로 처리하고 크기/JSON 예산·세션/input SHA·format/engine provenance에 결합한다. 기존 FIFO·HULLO·close-once·timeout/quarantine·복구를 유지한다. 실제 JNI 반환을 관측하기 전에는 실행 수용이나 편집 권위를 주장하지 않는다.
6. Root가 RED→구현→GREEN을 실제 실행한다. workers는 지정 파일만 편집한다. 모델/widget/controller/MCP·Rust SDK·Drive disk roundtrip·Android stub/JDK/native compile을 각각 분리해 기록한다. 새 소스 전체 검사와 설치 묶음은 이 구현을 합친 뒤 수행한다.

## 남은 전체 범위

이 단계로 표·열·목차·rich text, Android native 표/셀 구조 편집, 일반 Office fidelity, Notion AI/협업/기업 기능, S9+/S Pen·두 기기 실제 Drive·외부 LLM 사용을 완료로 표시하지 않는다. 현재 코드를 검토하며 다른 요구도 계속 구현하고 전체 항목별 실행 증거가 모일 때까지 목표를 active로 유지한다.

## 현재 검증 체크포인트

미디어 모델/화면/실제 Study→disk 재열기와 Rust stdio 왕복, 최종 MCP 게시 권한/판본 가드를 합친 source660/5591e159…의 전체 Flutter1675PASS/108skip·분석0을 확인했다. 후속 Android 자산 producer·R8·ARM64 포장과 MCP 외부 compiler target 설정 변경은 별도 before/after derivation으로 결합했다. 현재 source661/a4603127…의 새 Android136057 release/AOT 후보는 빌드·서명·메타데이터·Rust ELF/JNI 검사를 통과했고, 실제 Windows DLL9개 재실행·Android26개·Windows Python517개도 통과했다. 이전 간헐 WinError32는 원인을 고친 것으로 표시하지 않는다.

`build/validation/office-source-build57/checkpoint-android57-rust-status1.json`이 Android 입력·로그·APK와 canonical56 보존을 기록한다. 후속 Windows57 빌드는 exit0이며 실제 새 설치본의 schema17·미디어3·Rust DLL9·legacy21·PPT 기존 셀1·새 표/셀1 검사를 통과했다. E staging의 `candidate57-1/artifacts.json`에 ZIP/APK 후보와 파일별 검증을 결합했다. canonical56과 공개 preview.3은 유지하며57 승격·게시를 하지 않았다. 외부 Codex CLI는 세 모델 모두 계정의 model_not_found 응답으로 MCP 호출에 도달하지 못했다. Android 관측의 실기기 실행과 구조화 편집 연결, 전체 남은 범위는 계속 미완료다.

## 후속: 데이터베이스 행 본문 이미지·첨부

build57 후보와 검증 입력은 보존한다. 다음 소스 변경은 DB 전체 파일 snapshot에서 모든 행의 미디어를 검증하고 같은 판본에 저장한다. 일반 페이지와 동일한 이미지·첨부·전체128MiB 예산을 적용하며 불명 파일과 삭제된 미디어는 이력/undo를 위해 유지한다. 행마다 가짜 page.json을 만드는 우회는 사용하지 않는다. 기존 DB JSON 형식과 변경하지 않은 행의 unknown JSON을 보존한다.

1. 기존 controller API의 실제 disk 재열기·일반 저장 실패를 먼저 실행해 RED를 확인한다. DB snapshot/worker는 모든 행의 소유 등록부·공유 파일·전역 예산·무결성·동일 행의2→1 강등을 검사한다.
2. controller는 저장소·세션·선택 판본을 각 worker await 전후 확인하고 전체 파일과 추가 bytes를 함께 저장한다. 화면은 DB generation과 bytes를 같이 캡처하며 실패/재시도 중 draft를 유지한다. 행 본문 이미지·첨부 picker/read/save와 뒤로 이동을 기존 BlockPageEditor에 연결한다.
3. MCP는 DB 소유 판본 안의 rowId와 blockId로 미디어를 선택하게 한다. 일반 페이지의 rowId는 거절하고 DB에서는 필수로 검증한다. 문서 편집은 기존 최종 권한/expected-head 가드와 전체 파일 보존을 유지한다.
4. 모델·실제 disk·화면·Drive 두 disk·MCP/Rust schema를 범위별로 검증한다. 이 후속 소스를 기존 build57 APK/ZIP에서 검증한 것으로 표시하지 않으며, 실제 S9+/두 기기 Drive·외부 CLI 수용은 별도 미완료로 유지한다.

[확인] 후속 소스는663파일/93554636…이며 전체 Flutter1734PASS/108skip/0FAIL·Rust MCP38PASS·최종 분석0이다. 실제 Study4개와 UI44·controller37·모델/MCP/Drive46 범위 검사를 별도로 기록했다. 기존 opaque 파일 유실과 DB 미디어 거절, undo 뒤 읽기 실패, DB 전환의 이전 state 잔류를 실제 RED 뒤 수정했다. 전체 검사 뒤 테스트 const 한 단어만 추가한 exact raw-byte 파생과 Study4 재실행을 결합했다. `build/validation/database-row-media1/checkpoint1.json`이 입력·로그·보존 실패와 이전 묶음 manifest를 기록한다. 후속 소스의 새 Windows/Android 빌드와 설치 수용은 남아 있으며 기존 후보57을 이 소스로 바꾸지 않았다.

[확인] 이후 같은663/93554636…로 Windows58·Android136058을 빌드하고 E의 candidate58-1에 별도 묶음을 완성했다. 실제 Release schema17/Office30·DB media SDK1·DLL9·Study4·legacy21·PPT 셀1·새 표/셀1, APK 서명/ABI/AOT/JNI/ELF와 파일별 포장을 검증했다. candidate58-package2/exit0이며 이전56/57은 보존했다. 최신 해시·링크는 HANDOFF/README에 있다. 실제 S9+/두 기기 Google Drive/외부 LLM·남은 전체 Office/Notion 범위는 계속 미완료다.
