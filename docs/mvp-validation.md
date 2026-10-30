# MVP 개발판 검증 기록

## 태블릿 오류 수정판 preview.2 — 2026-10-30

- [확인] 사용자 S9+ 사진의 `MediaQuery`/`CanvasGestureDetectorState.initState` 오류가 실제 Android 화면 분기 회귀시험에서 재현한 오류와 일치했다. 최초 캔버스 변환을 첫 레이아웃 뒤로 옮겼다. 수정 APK의 기기 실행 성공을 확인한 것은 아니다.
- 새 노트/노트 열기 후 Drawer 닫기, 실패 알림 표시, PDF 실패 취소 후 완전 저장본 복구, 실패 PDF 캐시 해제의 오류 재발을 수정했다. 원본 PDF·기존 리비전을 유지하며 닫힌 세션의 늦은 저장을 거부한다.
- Android Drive 자동 복원은 보안 저장한 계정에 묶인 무화면 승인 요청으로 바꿨다. 손상된 연결 설정은 명시적 확인 후 원본을 고유 경로에 보관하고 복구한다. 자동 로그인 UI·원격 생성·업로드는 복구 동작에서 실행하지 않는다. 업데이트 후 수동 로그인/재연결이 한 번 필요하다.
- [확인] 최종 전체 Flutter **252개 통과 / 기존105개 skip / 0실패**, 23초, exit0. 전체 분석 문제0, 66.2초, exit0. 실제 작업공간→편집기→필기 획 저장→디스크 다시 읽기와 실패 PDF 취소·Drive 계정/복구 경계를 포함한다. 기존 skip 범위는 아래 기록과 동일하다.
- [확인] Android 최종 증분 빌드5.2초/exit0(직전 재컴파일 로그95.5초), 서명 검증 exit0. 버전0.1.0/code136032, package `io.github.canele452.personalinkvault`, minSdk24/targetSdk36, ARM64·ARMv7·x86_64. v2 서명과 기존 인증서 SHA-1 유지. 대응 소스는 `911b3fdf2db0e32732622e8fcd9f165b2f801b8d`다.
- [확인] [preview.2 릴리스](https://github.com/CanelE452/personal-ink-vault/releases/tag/v0.1.0-preview.2)의 [APK 다운로드](https://github.com/CanelE452/personal-ink-vault/releases/download/v0.1.0-preview.2/personal-ink-vault-android-preview.apk)는 **143079542bytes**, SHA-256 `184b1bf2184ee7c005bb38b4c87415e5232934925b2d604d327d6fdcb12f8ea4`. GitHub asset digest 일치, 인증 없는 다운로드 HEAD200/크기 일치를 확인했다.
- ZIP CRC·ARM64 PDFium·공개 Web ID 포함·사적 파일명 및 자격증명 payload 패턴 부재를 검사했다. 첨부 사진은 Git/릴리스에 포함하지 않았다. 기존 Windows PDFium DLL의 합성 A4 1쪽 실제 렌더링도 통과했다. 이는 Android native 실행 결과가 아니다.
- 로그는 Git 제외 `build/validation/tablet-preview2-*`와 `tablet-pdf-native-smoke.txt`에 있다. Windows native 재빌드, 수정판 S9+ 실행·펜 품질·native PDF·실제 OAuth/두 기기 Drive 왕복은 남아 있다. 아래 preview.1 기록은 이전 파일에 대한 결과다.

## Android 설치 파일 공개 — 2026-10-30

- [확인] 태블릿에서 받을 수 있도록 [v0.1.0-preview.1](https://github.com/CanelE452/personal-ink-vault/releases/tag/v0.1.0-preview.1)을 prerelease로 게시했다. [APK 직접 다운로드](https://github.com/CanelE452/personal-ink-vault/releases/download/v0.1.0-preview.1/personal-ink-vault-android-preview.apk)는 인증 없는 HTTP HEAD에서 200과 파일 크기 일치를 확인했다.
- [확인] 새 빌드 exit0, 141.9초. 앱 버전 `0.1.0`, versionCode `136031`, package `io.github.canele452.personalinkvault`, minSdk24, targetSdk36. debug 미리보기이며 ARM64·ARMv7·x86_64를 포함한다. ARM64 전용 APK라는 뜻은 아니다.
- [확인] APK `personal-ink-vault-android-preview.apk`: **143077302 bytes**, SHA-256 `9599e0ee8dfb922c57957802e2c601a69d2181f854c9fd8c5a8b40355d16f010`. 로컬 해시와 업로드 후 GitHub asset digest가 같다. v2 서명 검증 통과, 인증서 SHA-1은 기존 Google 등록값과 같다.
- 대응 소스는 `5181020983a6fa84540cfb916950d78a176f7550`. 빌드 시 `--debug --target-platform android-arm64 --no-pub --build-name 0.1.0 --build-number 136031`과 기존 공개 Web client ID define을 사용했다. 새 서명 키·토큰·개인 노트는 생성하거나 포함하지 않았다. 앱 소스 변경 없이 버전 인자만 지정했으며 이 작업에서 전체 단위시험을 반복하지 않았다. 같은 날 앞선 Dart51·Flutter237/105skip·분석0 결과는 아래 이력과 구분한다.
- APK ZIP CRC·공개 Web ID 포함·사적 설정/노트 파일명 부재와 실제 자격증명 payload 패턴 부재를 검사했다. 암호화 라이브러리의 PEM header 파서 상수는 비밀 키 본문이 아니다. 실제 S9+ 설치·펜·로그인·Drive 왕복 성공은 여전히 미검증이다.
- README의 PC 절대 경로를 실제 HTTPS 다운로드 링크와 저장소 상대 문서 링크로 교체했다. 아래는 2026-10-23까지의 이전 빌드 검증 기록이다.

## 이전 개발판 검증 — 2026-10-23

기준일: 2026-10-23. **개발을 시작한 검증판이며 전체 MVP 수용 기준 통과를 선언하지 않는다.** Windows C++ 도구 설치·Release 빌드와 Cloud OAuth 등록을 추가 완료했다. 앱에서의 실제 계정 동의·기기 왕복·Windows 실행 수용 시험은 남아 있다.

## 분석에서 구현으로

- Saber `55eec16ad6f858bc68b7c229e497c5ed44d7c5fd`: 펜·PDF 편집기 재사용, 앱 ID/저장 폴더 분리, Nextcloud·업데이트·Sentry 자동 전송 제거. 자체 저장 callback이 완전한 본문/첨부 snapshot을 불변 저장소에 발행한다.
- StarNote: PDF 필기 도구 흐름을 참고했다. 조사에서 확인하지 못한 `.note`·동기화 내부를 구현 근거로 쓰지 않는다. AI·녹음·전용 형식은 후속이다.
- Obsidian: Markdown 원문과 파생 검색 인덱스를 분리한다. 제목·페이지 순서와 무관한 UUID 링크를 쓰며 일반 역링크·그래프는 후속이다. 배포물 코드를 복사하지 않았다.

## 실행한 검사

- [확인] Flutter 3.47.7/Dart 3.13.5, JDK 25.0.4.1+1, Android compile SDK 37. Flutter 지정 NDK 28.2.13676358을 준비했다. 도구는 portable 경로와 현재 셸 환경만 사용한다.
- [확인] `flutter pub get`: 성공. 추가 수정 후 `flutter --suppress-analytics analyze --no-pub`: 전체 문제 0, **79.1초**, exit 0.
- [확인] 순수 Dart 저장/백업/Drive 시험: 2026-10-22에 **51개 통과**. 두 실제 디스크 저장소와 fake HTTP/remote를 사용한다. 이번 도구/OAuth 설정 작업에서 이 패키지는 수정하지 않았다.
- [확인] 추가 수정 후 `flutter --suppress-analytics test --no-pub --reporter expanded`: **237 통과 / 105 명시적 skip / 0 실패**, **44초**, exit 0. 실제 계정 동의 시험은 아니다.
- [확인] Android ARM64 debug APK: Web client ID를 포함한 최종 빌드 **38.2초**, exit 0. 서명 검증 exit 0, v2 서명과 기존 인증서 SHA-1 유지. APK의 원치 않는 startup provider 부재와 kernel snapshot의 공개 Web client ID 포함도 검사했다. 기기 설치·실행은 하지 않았다.
- [확인] Microsoft 서명이 유효한 공식 Build Tools 2022 **17.14.42**, MSVC·CMake·Windows SDK **10.0.26100.0**·ATL 설치 완료. 최종 경로는 `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`, 재부팅 필요 없음, Flutter doctor의 Windows 도구 검사 통과.
- [확인] Desktop client ID를 포함한 `flutter --suppress-analytics build windows --release --no-pub`: **125.1초**, exit 0. 실행 파일·DLL·data를 모두 포함한 로컬 ZIP을 만들었다. 실제 native 창·로그인 시험은 아직 하지 않았다.

로그는 Git 제외 경로 `build/validation/`에 남긴다. Cloud 프로젝트/client 등록과 앱의 실제 사용자 OAuth 동의·토큰 발급은 구분한다. 개인 노트 업로드·commit/push는 하지 않았다.

2026-10-23의 이전 APK는 `build/app/outputs/flutter-apk/app-debug.apk`, **185664855 bytes**, SHA-256 `5009fce4be7342eab41c1c75e23478fdcd150d73b07018c6caf0ae2363116dd8`이었다. 위 2026-10-30 다운로드 빌드와 구분한다. 앱 ID는 `io.github.canele452.personalinkvault`이며 upstream 앱과 분리된다.

Windows는 `build/windows/x64/runner/Release/personal_ink_vault.exe`를 같은 폴더의 DLL·data와 함께 실행한다. 전체 묶음은 `build/validation/personal-ink-vault-windows-x64.zip`, **21265032 bytes**, SHA-256 `b1cb7fc05b7ff63255a697d0c97655287912c810f69505dd50650c82826410e3`이다. 공개 Desktop client ID는 AOT snapshot에서 확인했다. exe 단독 복사는 지원하지 않는다.

## Windows·OAuth 후속 설정

- 첫 Windows 빌드는 도구 부재로 실패했다. 도구 설치 뒤에는 CP949의 UTF-8 소스 해석 경고(C4819, /WX)와 secure storage의 `atlstr.h` 부재를 확인했다. 공통 C++ 옵션에 `/utf-8`을 추가하고 ATL을 설치했다. 경고를 오류로 처리하는 `/WX`는 유지한다.
- 설치 인자의 공백 처리 실수로 최초 도구 경로가 `C:\Program`이 된 것을 발견했다. 이번에 생성한 instance를 확인한 뒤 공식 설치 프로그램으로 제거·표준 경로 재설치했고 모두 exit 0이었다. 이전 경로를 담은 생성 CMake cache는 빌드 폴더 안에서 이름을 바꿔 보존한 뒤 재생성했다. 소스나 사용자 자료를 삭제하지 않았다.
- Android에서 제거한 clipboard plugin의 `DataProvider` 선언이 남아 있었다. 최종 이전 APK의 manifest에는 선언이 있지만 DEX class가 없는 것을 확인했다. 선언 제거와 app-declared startup provider 소스 존재 회귀검사 추가 후 실패→통과를 확인했고 전체 시험은 1개 늘었다. 실제 기기 시작 성공을 뜻하지 않는다.
- [확인] 사용자 승인으로 새 Cloud 프로젝트 `personal-ink-vault`를 만들고 Drive API를 활성화했다. 사용자가 정책 동의를 직접 완료했다. 같은 프로젝트의 Android(debug package/SHA-1)·Web(Android server ID)·Desktop(Windows) client 3개, External Testing, 본인 테스트 사용자 1명, `drive.file`·`openid`·`userinfo.email` 범위를 등록했다. 민감/제한 범위는 비어 있고 전체 Drive 권한은 추가하지 않았다.
- 공개 ID는 Git 제외 `build/validation/oauth-client-ids.json`에만 기록했다. 두 최종 빌드에는 해당 플랫폼 공개 ID를 포함한다. client secret·access/refresh token은 빌드 인자나 문서에 넣지 않았다. Windows secret 입력과 실제 앱 로그인/Drive 동의는 본인이 [설정 안내](drive-setup.md)에 따라 진행한다.

이 PC의 설치 위치는 Codex MSIX의 로컬 캐시다. 일반 PowerShell에서 현재 프로세스에만 적용하는 예시는 다음과 같다. 다른 PC는 본인의 도구 경로를 전달한다.

```powershell
$inkTools = Join-Path $env:LOCALAPPDATA 'Packages/OpenAI.Codex_2p2nqsd0c76g0/LocalCache/Local/PersonalInkVault/tools'
. ./scripts/dev-tools.ps1 -FlutterRoot "$inkTools/flutter" -AndroidSdkRoot "$inkTools/android-sdk" -JavaRoot "$inkTools/jdk-25.0.4.1+1"
flutter --suppress-analytics --version
```

## 전체 Flutter 시험의 첫 결과와 처리

첫 전체 실행은 **237 통과 / 14 건너뜀 / 62 실패**였다. 실패를 기능 오류와 기존 upstream 전용 검사로 구분했다.

```text
39  기존 PNG와 pixel 불일치
12  미도입 upstream 배포 screenshot 및 plugin mock
 7  미도입 metadata/iOS/macOS/installer/Flatpak fixture 검사
 2  이전 Home 시작 경로·Nextcloud 계정 UI 기대
 2  Windows watcher 경로와 SBA archive handle 해제 결함
```

pixel 차이의 원인을 OS·폰트·엔진 중 하나로 단정하지 않는다. 기존 이미지 비교·배포 검사에는 명시적 upstream 실행 경계를 두고 원본 기대값을 유지했다. 새 baseline을 생성하지 않았다. 현재 시작 경로 시험은 workspace로 바꾸고, watcher·archive 결함 및 비픽셀 SBA roundtrip 시험은 기본 검사에 남겼다.

최종 skip 105개는 **기존 PNG 96 + 미도입 packaging 7 + 비활성 live Nextcloud 2**다. 현재 기본 시험 통과를 전체 upstream 시험 통과로 표현하지 않는다. SBN parsing 13개·SBA 본문/첨부 바이트 비교·즉시 원본 삭제·draw/undo/redo·Android locale·Dart 버전 검사는 기본 실행한다. 선택 실행 명령은 다음과 같다. 이 선택 검사들의 미해결 이미지 차이/필요 fixture는 [출처 기록](upstream-provenance.md)에 남겼다.

```text
flutter --suppress-analytics test --no-pub --dart-define=UPSTREAM_GOLDENS=true
flutter --suppress-analytics test --no-pub --dart-define=UPSTREAM_PACKAGING=true
```

## 저장·동기화 독립 검토

로컬 손상인데 `synced`로 표시되는 문제, 원격 외부 삭제 복원 뒤 오류가 풀리지 않는 문제, 과거 모든 snapshot의 같은 PDF를 반복 검증하는 문제를 회귀시험으로 재현하고 수정했다. 독립 재검토에서 해당 세 건의 해소와 51개 시험 통과를 확인했다.

합성 50MiB 동일 자산과 작은 본문을 5회 저장한 실측:

```text
수정 전 ms  1365  1837  2860  3168  4290
수정 후 ms   795  1137  1135  1166  1138
```

캐시는 단일 repository 인스턴스에만 적용하고 재열기·명시적 읽기/import에서 실제 파일을 검증한다. 이 수치는 실제 PDF 100페이지 좌표·필기 시험 결과가 아니다.

## 통합 검토에서 수정한 경계

- 원격 Markdown 읽기가 끝나는 동안 새 입력·세션 전환·필기 저장이 일어나도 결과와 부모 리비전이 되돌아가지 않는다.
- 펜·지우개·선택 제스처 시작부터 busy 상태를 유지하고 미완성 gesture를 캡처하지 않는다.
- PDF 초기 import를 원래 세션에 고정한다. 최초 canonical 저장 성공까지 전환을 막고 실패 시 같은 pageId/원본 bytes로 재시도한다.
- capture·save·reload를 직렬화하고 이전 writer를 닫은 뒤 새 저장소 인덱스를 연다.
- Markdown을 500ms debounce로 로컬 저장한다. Windows 정상 창 종료는 flush를 기다리고 실패하면 창을 유지해 재시도한다. 초기화 오류로 작업본이 없는 창은 닫을 수 있다.
- Windows watcher는 가상 상대경로를 발행하고 SBA 입력 handle은 모든 반환/오류 경로에서 닫는다.

위 경계는 지연된 읽기·capture·commit, 저장 실패와 초기화 실패 회귀시험으로 확인했다. 독립 검토의 5 P1, FileManager 2건, 잔여 P2는 모두 해소 판정을 받았다. Windows close는 host widget/native-channel mock 시험이며 실제 native 창 시험을 대신하지 않는다. 강제 OS 종료까지 미저장 입력을 보존한다고 주장하지 않는다.

## 남은 실사용 gate

1. Windows Release 앱의 실제 실행·저장·정상 종료 수용 시험. C++ 도구 설치와 native 빌드는 완료했다.
2. [Drive 설정](drive-setup.md)에 따른 앱의 실제 로그인/권한 동의. Cloud client 등록은 완료했으며 두 기기의 같은 vault 접근·실제 양방향 왕복은 남아 있다.
3. S9+의 실제 OS/펜 확인과 압력·손바닥·확대·종료 복구, 회전/CropBox/혼합 크기 PDF 및 100페이지/약 50MB 시험.
4. 실제 Android WorkManager/headless 인증·전경 복귀·절전 제한, 정상 종료와 오류 재시도 시험.

Windows 종료 중 상주 동기화, OS 딥링크 등록, 작업본/원격 blob GC, E2E, 별도 Drive 백업 스냅샷은 현재 보장하지 않는다. 백업은 로컬 JSON/base64, encoded 128MiB 기본 제한이며 메모리는 그 수배를 쓸 수 있다. 원본 아이콘 교체와 전체 native/자산 라이선스 감사도 외부 배포 전에 남아 있다.
