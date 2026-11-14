# Windows 전체 Office 편집창 연결

사용자 목표는 Android·Windows에서 폴더/문서·필기·Markdown·Office 원본을 편집하고 Drive로 이어 쓰는 전체 작업공간이다. 이 단계는 Windows의 전체 Office 편집창 연결이며 Android·Obsidian·Notion·MCP의 남은 요구를 대체하지 않는다. 사용자 지시에 따라 추가 질문 없이 진행한다.

기존 Windows 경로는 Flutter의 구조화된 편집 항목에서 `WindowsOfficeEngine.apply`를 호출했다. 후속 소스는 generic 상태 DTO·Dart 서비스와 전체 LibreOffice 편집창을 기본으로 여는 UI를 연결하고, 기존 구조화 편집은 보조 경로로 유지한다. 기존 `OwnedOfficeProcess`의 Job 소유권과 `OfficeServer`의 별도 프로필·pipe를 재사용한다. 기본 headless 동작은 유지하고 명시적으로 요청한 대화형 문서만 표시한다. 매크로와 외부 문서 업데이트는 계속 차단한다. 이 연결의 최종 수용은 진행 중이다.

1. [x] 실제 생성/로딩 속성과 Job-before-resume를 검사하는 RED를 실행한다.
2. [x] 정확한 boolean `show_window`/`interactive` 선택을 추가하고 기본값·실패 정리를 검증한다.
3. [x] 고정 private PPTX를 번들 런타임의 실제 GUI 문서로 열어 창의 native visibility, 수정·저장·독립 재열기·PDF와 원본 불변을 관측한다. UI 자동화나 S9+ 실행과 구분한다.
4. [x] **구현·host/실제 native API 검증 완료:** 앱의 편집 시작을 private working copy·durable recovery에 결합한다. 사용자 편집 중에는 짧은 headless timeout을 적용하지 않는다. 취소·앱 종료·엔진 실패 때 소유 프로세스만 정리하고 복구 파일을 보존한다.
5. [x] **구현·host/실제 native API 검증 완료:** GUI 종료 뒤 저장한 파일을 다시 검사하고 source/PDF를 같은 판본으로 반영한다. 저장 실패·응답 유실·다른 판본 전환·재시도에 기존 보호를 유지한다.
6. [x] 현재 소스의 회귀·분석·Windows60/Android136060 빌드와 실제 Release 검사·새 E candidate60-3 묶음을 검증한다. 기본 Dart 서비스→PS→Office의 실제 저장·반영 취소도 각각 검증한다.
7. [ ] standalone Flutter GUI의 진입·편집·저장·재열기와 사용자의 닫기 대화상자를 수용 검증한다. S9+/S Pen·두 기기 Drive·외부 LLM과 전체 기능은 별도 미완료 범위로 유지한다.

Android 실행 검증도 별도 의무다. 2026-11-06 이 PC의 새 isolated SDK37.2.13/API35에서 x86_64 소프트웨어 부팅은 중단·native crash를 보였고 ARM64 AVD는 호스트 아키텍처 제한으로 거절됐다. 앱 설치/실행 전 실패이며 Android 앱 또는 Rust의 성공/실패 증거가 아니다. E의 테스트 SDK/AVD와 `build/validation/android-emulator1`에 기록을 보존한다. OS 가속기·전역 AI/Google 설정 변경은 하지 않았다.

기반 검증: 새17개 및 당시 전체 Python534개가 통과했다. 첫 전체 실행의 parent-response WinError32 한 건은 원인 미해결이며 원 로그를 유지했다. 실제 GUI probe3은 합성 native2×2 표의 한 셀을 바꾸고 별도 엔진으로 재열어 PDF1쪽과 원본 불변·두 프로필 정리를 확인했다. 그보다 앞선 기존 fixture의 native 표 수 단언 실패와 프로필 잔여 실패도 보존했다. 이 기반은 source666/9d8a212e…의 결과다.

현재 후속 검증: backend33개·startup/PS wrapper8개와 취소 중 source 복사 focused1개가 통과했다. 실제 OS parent-bound Job은 부모 종료 시125·소유 child 종료·무관한 프로세스 생존을 확인했다. native1은 TEMP=launch135자/profile 내부264자에서 startup Timeout/loader0이었고, 같은 source673/e3cee60c…의 짧은 TEMP-only native2는 실제5개 API 제어 사례(save/discard/cancel/Save As 거절/deep-save230자)를 모두 통과했다. PPTX/XML·PDF 저장 marker/SHA 일치·미저장 memory 제외, 정상 profile 제거·Save As 실패 profile 보존을 확인했다. Flutter/CUA·사용자 닫기 수용은 아니다. service가 만든 짧은 private cache를 상속하고 전역 TEMP를 바꾸지 않으며, wrapper가 launch로 덮지 않는다. Python native 초기화가 GIL을 막은 채 부모가 살아 있는 경우의 phase timeout까지 외부 Job이 보장한다고 주장하지 않는다.

전용 short cache·취소 파일 writer drain·요청 atomic 게시를 포함한 focused40개+UI11개=51PASS/0skip/exit0이다. 이후 현재673/46176c65…에서 새 전체 Flutter1830PASS/108skip/0FAIL/1분47초·분석0/79.2초와 Windows60/Android136060 실제 빌드·Release cohort를 확인했다. 기본 Dart 서비스→PS→실제 Office의 저장24초·반영 취소18초가 각각1PASS이며 proof3 checkpoint27289bytes/SHAce7eed9b…e83427에 결합했다. candidate60-3의 ZIP/APK/manifest는 실제 포장3/exit0과 독립 크기/SHA로 확인했고 이전56~59는 보존했다. 이는 standalone Flutter GUI·사람의 닫기 수용이 아니므로7단계를 남긴다. 실제 Windows Release Rust DLL9개는0skip/exit0이며 Android 실기기는 미검증이다. Python full1의575개 중1FAIL은 원인 미확정이고, 원 assert·drive/wait를 유지한 단독10PASS·진단 repeat575PASS를 원인 수정으로 표시하지 않는다. [후속 검증 기록](../../mvp-validation.md)을 따른다. 전체 목표는 계속 활성/미완료다.
