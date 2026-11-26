# Personal Ink Vault

개인 PDF 필기와 Markdown 정리를 연결하는 Flutter 앱입니다. 이번 공개판은 Android 휴대폰과 태블릿에서 사용할 수 있습니다.

## Android 휴대폰·태블릿에 설치

**[Android 232 APK 바로 다운로드](https://github.com/CanelE452/personal-ink-vault/releases/download/v0.2.0-android.232/personal-ink-vault-android-0.2.0-build232-136232-arm64-release.apk)**

1. Android 휴대폰 또는 태블릿에서 위 링크를 누릅니다.
2. 다운로드한 APK를 열고 기존 Personal Ink Vault 앱을 업데이트합니다.
3. 앱에서 새 노트, PDF 필기 또는 Office·한글 원본을 엽니다. Drive를 연결하려면 앱의 **Drive → Google 로그인 / 재연결**을 사용합니다.

Android 8.0 이상과 ARM64 기기를 지원합니다. APK 크기는 약 405MB입니다. [릴리스 정보](https://github.com/CanelE452/personal-ink-vault/releases/tag/v0.2.0-android.232) · [Android 232 대응 소스](https://github.com/CanelE452/personal-ink-vault/tree/v0.2.0-android.232)

### 231 이후 바뀐 점

필기 화면을 새로 지었습니다. 보관함·리마인더·달력은 231 그대로입니다.

- 위쪽 도구 막대: 쪽 목록과 노트 창 단추, 필기/제스처 바꾸기, 도구(올가미·펜·지우개·텍스트·모양·사진·레이저 펜), 오른쪽의 노트 추가·전체 화면·⋯ 한 줄입니다. 막대에는 도구를 최대 6개 두고 나머지는 ⌄에서 고르며, 거기서 「도구 막대 사용자화」를 엽니다. 휴대폰처럼 좁으면 단추를 숨기지 않고 옆으로 밉니다.
- 떠 있는 막대: 펜이나 지우개 단추를 누르면 위에 떠서 종류·색·굵기를 고르게 하고, 같은 단추를 다시 누르면 사라집니다.
- 펜 창: 펜 종류, 굵기, 색을 한 창에서 고르며 고른 설정이 바로 선에 반영됩니다.
- 지우개 창과 올가미 창: 지우개는 방식(획 지우개·원형 선택 지우기)과 크기 셋, 고급 설정(지울 대상, 자동 해제, 쪽 지우기)을 둡니다. 올가미는 단추를 한 번 더 누르면 유형(자유·사각형)과 선택 대상(손글씨·형광펜·도형·사진)을 고르는 창이 열립니다.
- ⋯ 메뉴: 맨 위에 문서 정보·이름 바꾸기·쪽 배치(세로로 이어 보기/가로로 넘기기)가 있고, 그 아래에 검색·보기·지우기·설정 묶음이 이어집니다.
- 예전 도구 막대와 그 설정 창, 오른쪽 기타 설정 패널은 없어졌습니다. 아직 기능이 없는 이모지·녹음·자는 보이지 않습니다.

232는 PC에서 위젯 시험과 빌드 검사를 거쳤고 실기기 확인 전입니다. 새 필기 화면을 태블릿에서 확인할 예정입니다.

### 229 이후 바뀐 점(230·231)

230과 231의 변경입니다. 필기 화면은 229 그대로 두고, 그 밖의 화면을 Notein처럼 바꿨습니다.

- 보관함: 위 줄 아이콘, 분류 탭 넷(모두·PDF·메모·폴더), 격자·목록 보기, 즐겨찾기 하트·날짜·쪽 수가 보이는 카드로 바꿨습니다. 카드 메뉴는 제목 바로 옆 ⌄에서 열며 고정·이름 바꾸기·표지 변경·라벨 추가·이동·휴지통·상세 정보가 있습니다. 오른쪽 아래 연필은 새 노트를 바로 만들고, +는 추가 메뉴를 엽니다.
- 표지: 기본은 문서의 첫 쪽입니다. 한글·PPT·Word 문서는 표지 왼쪽 위에 형식 표시가 붙습니다. 「표지 변경」에서 첫 쪽, 형식 표지, 단색 8가지를 고릅니다. 미리보기 그림이 없는 Word·Excel 등은 「첫 쪽 표지 만들기」를 눌러야 첫 쪽 표지가 됩니다.
- 서랍(옆 패널): 모두·최근·즐겨찾기·리마인더·달력·휴지통, 폴더, 라벨이 있습니다. 「최근」은 최근에 연 문서 50개입니다.
- 가져오기가 화면을 막지 않습니다. 가져오는 문서는 그 자리 카드에 진행률과 취소 단추가 보이고, 그동안 다른 문서를 열거나 다른 파일을 가져올 수 있습니다. 끝나면 알림 줄로 알립니다.
- 필기 노트의 링크: 올가미로 고른 것이나 누른 자리에 쪽·노트·웹 링크를 겁니다. 밑줄과 파란 사슬 배지로 보이고, 배지를 누르면 따라갑니다.
- 리마인더와 달력: 보관함에 하나씩 있습니다. 달력에는 편집 모드와 필기 모드가 있고, 「Google 캘린더 연결」로 Google 캘린더 일정을 읽고 씁니다. 홈 화면 위젯 두 개(리마인더, 달력)와 리마인더 알림이 있습니다. 알림을 위해 알림 권한을 묻고, 정확한 시각 알람과 기기 재시작 후 알림 다시 예약 권한을 씁니다.
- 손글씨 인식(231): 달력 필기 모드에서 날짜 칸에 쓴 글씨를 「글자로 바꾸기」로 그날 일정의 글자로 바꿉니다. Google ML Kit 손글씨 인식을 쓰며, 한국어·영어 모델을 처음 쓸 때 Google에서 받습니다. 받기 전에 크기를 알려 줍니다. ML Kit 관련 고지는 [고지](THIRD_PARTY_NOTICES.md)에 있습니다.

231의 홈 화면 위젯, 반복 리마인더 알림, 가져오는 카드, 표지, Google 캘린더 연결, 손글씨 인식은 아직 기기 확인 전입니다. 228의 Office·한글 편집기 동작, 227의 닫을 때 묻는 조건, 226의 스트로크 안정화, 217에서 남은 한글 저장·HWPX 편집 확인, 두 Android 기기의 Drive 왕복 검증도 아직 기기 확인 전입니다.

"PDF 필기용"으로 저장한 노트는 일반 PDF 노트로 열리며, Office 편집용으로 바꿀 수 없습니다. Office·한글 문서에서 "PDF로 새 문서 만들기"를 누르면 같은 폴더에 별도 PDF 노트가 생기고, 원본은 그대로 남습니다.

Android 빌드에 필요한 소스는 이 저장소의 기본 브랜치에 있으며, [빌드 안내](#android-arm64-빌드)와 [파일별 해시](SOURCE-MANIFEST.json)를 확인할 수 있습니다.

## 프로젝트 현황

Saber 고정 소스 기반 검증판과 자체 불변 저장·Drive 모듈을 개발 중입니다. 세 앱 분석을 반영한 [설계](docs/mvp-design.md), [개발 현황](docs/roadmap.md), [검증 기록](docs/mvp-validation.md)을 먼저 확인하세요. 코드 시험 통과와 실기기·실제 Drive 왕복 검증은 구분합니다.

폴더·문서 표지 홈과 생성 메뉴, Rust 공통 핵심, Office·한글 원본 편집은 [확대 설계안](docs/library-workspace-design.md) 검토 단계입니다. 기업의 Rust 구성 사례와 기존 데이터 이전 조건도 정리했습니다.

공개 저장소: [CanelE452/personal-ink-vault](https://github.com/CanelE452/personal-ink-vault). 기준 브랜치는 `main`이며 앱 소스·문서·공개 시험 자료를 관리합니다.

## 읽기 순서

1. [Saber 재사용 검토](docs/saber-reuse-review.md)
2. [MVP 설계](docs/mvp-design.md)
3. [개발 계획](docs/roadmap.md)
4. [StarNote 공식 APK·기능 정적 조사](docs/starnote-investigation.md)
5. [Obsidian 저장·링크·검색·그래프 정적 조사](docs/obsidian-investigation.md)

장기 요구·초기 비교: [요구사항](docs/requirements.md), [후보 비교](docs/architecture-options.md), [호환성 조사](docs/compatibility-research.md). 작업 이력은 [_docs/history](./_docs/history/2026-10-22.md), 인계는 [HANDOFF_KO.md](HANDOFF_KO.md)입니다.

## 코드와 개인 데이터

GitHub는 공개 코드·문서·합성 시험 자료만 관리합니다. 개인 PDF·필기·첨부·백업은 비공개 Drive와 저장소 밖 로컬 vault에 둡니다. APK·외부 앱 추출물·토큰·서명 키도 Git에 넣지 않습니다. [.gitignore](.gitignore)는 공개 전 파일 검토를 대신하지 않습니다.

설치용 앱 APK는 위 GitHub Releases의 첨부파일로 제공합니다. 개인 노트·OAuth 토큰·서명 키는 릴리스에도 포함하지 않습니다.

Drive 자동 동기화와 독립 백업/복원을 함께 구현합니다. portable 개발 도구를 준비했으며 Google OAuth 동의·개인자료 업로드는 아직 하지 않았습니다. 토큰은 OS 보안 저장소에만 두고 백업·로그·Git에서 제외합니다.

## 검증 범위

- Saber는 고정 커밋의 소스 경로를 추적하고 Android·Windows 개발판 빌드를 확인했습니다. 실제 기기의 필기 품질과 두 기기 Drive 왕복은 미검증입니다.
- StarNote 1.5.4 공식 APK의 Manifest·archive·리소스를 조사했습니다. 본체 동작/.note/Drive 호환·서명 검증은 미완료입니다.
- AI·OCR·그래프·일반 역링크/태그·iOS·StarNote 가져오기는 후속 제안입니다.
- Obsidian 기능을 참고해 자체 구현하며 해당 앱 코드를 복제하지 않습니다. 외부 코드 통합 전 출처·라이선스·의존성 조건을 확인합니다.

기준일: 2026-10-22. 공식 안내, 정적 관찰, 실기기 결과를 구분합니다.

## Android ARM64 빌드

1. Flutter `3.47.7`의 [고정 소스](https://github.com/flutter/flutter/tree/abaf9c523780a608bd46686fd5e53740a07077f8), Dart `3.13.5`, JDK `25.0.4.1+1`, Android SDK 및 Python 3.11 이상을 준비합니다. Flutter SDK가 래퍼를 준비하고 `android/gradle/wrapper/gradle-wrapper.properties`에서 Gradle `9.5.0`을 선택합니다. Gradle 데몬에는 저장소의 JVM 설정에 따라 JetBrains JDK 21을 자동으로 준비하거나 기존 설치를 사용합니다.
2. Android SDK의 `platforms;android-37.0`, `ndk;28.2.13676358`, `ndk;29.0.14206865`, `cmake;3.22.1`을 준비합니다. Rust `1.99.1`에 `aarch64-linux-android` 타깃을 추가합니다. Android SDK 경로를 `ANDROID_SDK_ROOT`로 지정하세요.
3. 한글 PDF 엔진은 아직 출시되지 않은 rhwp 커밋을 씁니다. 먼저 [한글 엔진·편집 화면 빌드](docs/hwp-rhwp-build.md)에 따라 rhwp 원본을 받아 `packages/ink_hwp_native/Cargo.toml`의 임시 경로를 맞춥니다. 같은 문서에 따라 한글 편집 화면(rhwp-studio)을 빌드해 `android/app/src/main/assets/hwp-studio/`에 넣으면 APK의 `assets/hwp-studio/`로 들어갑니다.
4. 소스 루트에서 `bash scripts/build-android-232.sh`를 실행합니다. Android Gradle 작업이 두 Rust 라이브러리, 한글 렌더링·내보내기 글꼴, Office Android 라이브러리를 준비합니다. 출처는 Cargo 잠금 파일, 글꼴 manifest 및 [Office 엔진 잠금 파일](android/office_engine/engine.lock.json)에서 확인할 수 있습니다.
5. 사용자 본인의 서명 키로 설치용 APK를 만들려면 `android/key.properties`에 `storeFile`, `storePassword`, `keyAlias`, `keyPassword`를 로컬로 지정합니다. 서명 전 빌드만 하려면 이 파일 없이 빌드할 수 있습니다. 본인의 OAuth 공개 클라이언트 ID로 테스트하려면 `DRIVE_ANDROID_SERVER_CLIENT_ID`를 설정합니다.

스크립트는 ARM64의 빌드 번호를 `136232`로 지정합니다. 공개 APK는 유지관리자의 기존 서명 키와 공개 OAuth 클라이언트 설정을 사용합니다. 로컬 재빌드는 키와 빌드 환경에 따라 APK 바이트가 달라질 수 있습니다.

## 고정된 업스트림 소스

- Office Android Java·C++ 및 편집기 웹 리소스는 [Collabora Online 고정 리비전](https://github.com/CollaboraOnline/online.mirror/tree/fd0b24ba59e043b2ed9087eb6324bbc6d281e93b)에서 확인할 수 있습니다. [엔진 준비 스크립트](android/office_engine/prepare_engine.py)는 잠금 파일의 공식 APK와 소스 파일 해시를 확인하고, 앱의 Android 통합에 필요한 변경을 적용합니다. 자세한 내용은 [Office 소스 안내](android/office_engine/README.md#source-and-notices)에 있습니다.
- PDFium의 기본 Android 네이티브 배포물은 Flutter 의존성의 빌드 훅에서 받습니다. [PDFium 고정 소스 계열](https://pdfium.googlesource.com/pdfium/+/refs/heads/chromium/7811)과 [Android PDFium 빌드 스크립트](scripts/build_pdfium.sh)를 이용할 수 있습니다.
- 한글 처리 라이브러리는 [hwp-cli 고정 리비전](https://github.com/STAIxBWLB/hwp-cli/tree/4e6e8c2a61694899e37b4f7c2f97523153a623b9)과 [Cargo 잠금 파일](packages/ink_hwp_native/Cargo.lock)에 연결됩니다. 한글의 PDF 변환과 편집 화면은 [rhwp 고정 커밋](https://github.com/edwardkim/rhwp/commit/4cf97fe5f40bde52b6e80dfc461b5111b51139b6)(PR #9022, MIT)으로 만들며, 받는 방법과 앱이 더한 패치는 [한글 엔진·편집 화면 빌드](docs/hwp-rhwp-build.md)에 있습니다.
- Dart 의존성은 [pubspec.lock](pubspec.lock), 공통 Rust 엔진은 [Cargo.lock](packages/ink_vault_native/Cargo.lock)을 사용합니다.

Android 아이콘 원본은 `assets/icon/`의 세 SVG입니다. 변경 후 `python scripts/generate_android_icons.py`로 PNG를 다시 만들 수 있습니다. 동일한 렌더러를 사용하려면 `PyMuPDF==1.28.2` 및 `Pillow==12.0.0`을 설치하세요.

## 개발판 실행

Flutter 3.47.7/Dart 3.13.5와 Android SDK가 필요합니다. Windows 실행 파일 빌드에는 Visual Studio의 Desktop development with C++ 도구가 추가로 필요합니다. 기존 도구 경로를 현재 셸에 적용하는 `scripts/dev-tools.ps1` / `scripts/dev-tools.sh`를 제공합니다.

```text
flutter --suppress-analytics pub get
flutter --suppress-analytics test --no-pub
flutter --suppress-analytics run -d <DEVICE_ID>
```

저장소 패키지의 시험은 `packages/ink_vault_core`에서 `dart test`로 실행합니다. 첫 화면에서 오프라인 노트/PDF를 만들 수 있습니다. Android는 필기와 Markdown 열람, Windows는 필기 보기와 Markdown 편집에 집중합니다. Drive는 [별도 설정 안내](docs/drive-setup.md)에 따라 같은 Google Cloud 프로젝트의 client를 등록하고 사용자 동의를 완료해야 연결됩니다. 설정 전에도 로컬 저장은 동작합니다.

이 코드는 GPL v3인 Saber 기반입니다. 초기 포크의 고정 소스·변경·제약은 [출처 기록](docs/upstream-provenance.md), 의존성은 [고지](THIRD_PARTY_NOTICES.md)를 참고하세요.
