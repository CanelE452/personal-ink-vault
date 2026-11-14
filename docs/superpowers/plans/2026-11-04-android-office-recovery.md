# Android Office 편집의 재시작 복구

사용자의 태블릿·휴대전화·Windows 필기/Office/Obsidian/Notion/MCP 전체 목표를 계속한다. 직전 build50은 이력 MCP를 추가해 실제 로컬 묶음까지 검증했다. 이번에는 태블릿에서 편집한 원본·PDF와 공개 계획을 앱 종료 후 발견하고 사용자의 선택으로 이어가는 실제 경로를 연결한다. 전체 목표를 이 기능만으로 완료 처리하지 않는다.

## 현재 근거

- OfficeWorkspace는 native 실행 전 Flutter 작업 원본을 만들지만, native 결과·OfficePreparedEdition은 메모리에만 둔다. native 결과를 받은 뒤 generation guard에서 버리면 파일과 문서의 연결도 남지 않는다. back/save는 pending을 자동 공개하므로 발견한 복구 후보는 별도 상태여야 한다.
- Bridge는 별도 files/office-sessions/<UUID>/working.ext를 만들며, caller sessionId와 callback은 메모리에만 있다. 새 Bridge는 pending=null이면 도착한 Activity 결과를 버린다. 원본 export→PDF export→형식/페이지/hash 검증 후 setResult이지만, 검증 결과를 디스크에서 재발견할 marker가 없다.
- 실제 REA 6.7.0/JADX0.7.1로 공식 Collabora APK `70b2d7456de59e463efbed1c7382e749f814632b436d2b395f1b0ae1e81ce180`의 LOActivity를 다시 조사했다. class `ev_2bc9d6aab752c922a88810e1477e9d5e1263cc71e8d02a42f5c3847af5e2c899`, onPause `ev_f79cb1bd5b61d528469ad598ec726eb94d7dd2dc0b9e1e2cf459d101328db7b4`, onSaveInstanceState `ev_31efa479e7ddb81ab35e674acc4babf8cc02ab0a9bd9a6aeb83d2cff1d543757`, onDestroy `ev_938b7dbe343a44ad6261cd05ed33b5fd62637bd42c9a862e7c852aa8d616e23b`다. 세 메서드는 Java body complete/no fallback이다. onPause는 저장 hint를 보내며 완료 확인은 없다. saved state는 URI/provider/editable 정보다. 이는 공식 APK 정적 관측이며 S9+/우리 JNI 실행 근거가 아니다.
- 연결 MCP의 JADX 경로 미설정 실패 뒤, 기존 검증된 JAR/JDK를 npx --offline pinned CLI 프로세스에만 지정했다. 전역 설정/설치는 변경하지 않았다. 원본 full-output/exit는 ignored `android-office-recovery-rea-*`에 있다.
- [Android 공식 저장 상태 안내](https://developer.android.com/topic/libraries/architecture/saving-states)는 프로세스 종료를 견디는 큰 앱 데이터는 로컬 영속 저장과 작은 재구성 ID로 다루도록 설명한다. 이 앱의 설계 판단은 위 실제 경로에 durable 파일 기록을 추가하는 것이다. 마지막 미확정 입력까지 무조건 보존한다고 주장하지 않는다.

## 계약과 소유

1. **Office store — page_history_domain**
   `OfficeEditSession.toRecoveryDescriptor()`와 `resumeEditSession(note,{descriptor})`는 version/root/vault/device/format/note/metadata/source/parents/filename/sourceSHA에 결합한다. 실제 historical metadata·source record와 bytes를 검증하고 부모를 최신 head로 바꾸지 않는다.

   `OfficePreparedEdition.toRecoveryDescriptor()`·`copyRecoveryFiles()`와 `resumePreparedEdition(note,{descriptor,files,beforePublish})`는 exact revision/binding과 원본·preview.pdf·edition.json 세 bytes를 재사용한다. envelope는 `{version:1,noteRevisionId,sourceRevisionId,requireCurrentHeads,prepared:<core descriptor>}`다. 정책 bool 자체는 인증 토큰이 아니며 상위 저널의 association/digest가 원래 요청을 결합한다. callback은 새 실행 환경에서 재주입한다. 공개된 판본은 실제 manifest/payload를 확인해 같은 결과로 응답하고 후속 branch/descendant를 되감지 않는다.

2. **Native — mcp_page_history_sdk**
   기존 edit/preview 계약을 유지하고 `recover(sessionId,inputSourceSha256)`와 `resume(sessionId,inputSourceSha256)`를 추가한다. recover는 missing/working/saved를 반환한다. 최초 inputSHA와 현재 workingSHA를 구분한다. private UUID 폴더의 session/source/format binding은 launch 전에, saved marker는 원본/PDF 전체 검증 뒤 setResult 전에 원자적으로 기록한다. saved 재조회는 exact 파일/hash를 확인하며 부분 export를 성공으로 취급하지 않는다. working 재개는 같은 private 작업 복사본을 열고, saved는 기존 결과를 검증해 돌려준다. 다른 live editor가 있으면 중복 엔진을 열지 않는다. preview는 복구 대상이 아니다. Java/Kotlin·standalone harness를 소유한다.

3. **Vault-local journal — core_prepared_recovery**
   기존 `.workspace` 구조의 별도 Office 편집 저널을 사용한다. 실행 전 captured binding → native saved 파일·hash → exact prepared descriptor/세 파일 → 실제 공개 확인 뒤 completed를 await 순서로 기록한다. 새 instance가 note에 속한 후보를 발견하고 사용자가 보관한 상태도 기억한다. 원본/PDF/기존 작업 파일을 자동 삭제하지 않는다. 상세 UI-facing API는 읽기 제안 후 root가 결합한다.

4. **Dart channel/UI/integration — root**
   현재 note를 열 때 복구 후보를 별도 표시하고 사용자가 이어 편집/이어 저장을 선택한 때만 pending으로 올린다. 뒤로가기로 발견한 후보를 자동 공개하지 않는다. 늦은 native saved 결과는 captured journal에 먼저 기록한 뒤 UI generation을 확인한다. 다른 vault/note로 연결하지 않고 파일 보관 선택도 영속화한다.

## 검증·적용 순서

- [x] Store의 새 fresh-repository 복구 시험 RED → 구현 → 기존 Office/MCP writer 회귀.
- [x] native journal/protocol의 실제 파일·부분 출력·결과 전달 유실·재개·busy/path 검증 시험 RED → 구현. standalone Java와 Android compile은 실제 JNI 실행과 구분.
- [x] vault journal의 단계별 중단·같은 revision/binding·보관/오염/scope 시험 RED → 구현.
- [x] 실제 UI 재구성·복구 선택/뒤로·늦은 결과·remote branch·저장 실패/응답 유실 통합.
- [x] 리뷰·전체 시험/분석·Windows/Android 빌드와 설치 묶음 검증 후 다음 로컬 개발판. 기존 build50 ZIP/APK/manifest는 새 gate 완료 전 유지.

실행/빌드/formatter는 root만 담당한다. 제품 수정 전 관련 RED를 root가 확인한다. 다른 작업자의 변경을 보존한다. 새 의존성·전역 AI 설정·vault 형식·엔진 timeout은 바꾸지 않으며 commit/push/게시하지 않는다. 실제 S9+·S Pen/Drive 두 기기와 전체 Office/Notion 동등성은 별도 남은 요구다.

## 빌드 전 검증

전체 Flutter1109PASS/108skip/0FAIL(5분11초)·분석0(7.1초), Office/MCP 집중447PASS/3skip, core150PASS다. 집합이 겹치는 수를 합산하지 않는다. Native plain JDK의 실제 파일·별도 JVM·stub Activity7개와 기존 lifecycle2개도 통과했다. 정상 EOCD comment·작은 ZIP64와 필수part/CRC/실제 해제 크기/Unix link/CEN 정렬 검사를 포함한다. 실제 Android JNI·프로세스 종료·S9+ 동작을 시험한 것으로 확대하지 않는다.

새 parser의 CEN 기준 위치 차이는 실제 JDK 회귀로 재현한 뒤 정확한 끝 정렬로 수정했다. 첫 native6개 성공과 초기 source snapshot은 attempt1 파일로 보존했다. 최종 runtime604파일 지문은 `33a84c0a8b6f46bfb6768671f6fd1dc8b2921981cf59a5c21fd038a7e4960bed`이며 Windows51·Android136051 빌드와 설치 묶음 검사를 진행한다. 기존50의 Word142/세 native 관측은37 Python bytes 일치·증거 SHA로 재사용하고 새 실행으로 세지 않는다. MCP exe도50과 같은 실제 bytes를 검증하며 설치 엔진 시험은 새 묶음에서 따로 실행한다.


## build51 최종 묶음

Windows51·Android136051과 로컬 APK/ZIP/manifest 승격, 설치 MCP/문서 엔진16개·DLL9개, APK 복구 코드 포함·최종45개 검사를 통과했다. 정확한 파일·해시와 남은 실기기 범위는 [검증 기록](../../mvp-validation.md)을 따른다. 전체 목표는 계속 미완료다.
