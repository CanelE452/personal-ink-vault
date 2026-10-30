# Personal Ink Vault

개인 PDF 필기와 Markdown 정리를 연결하는 Flutter 앱입니다. **첫 MVP는 Galaxy Tab S9+ PDF 필기 → Windows에서 필기를 보며 Markdown 정리 → Drive 자동 동기화**입니다. iPhone·iPad는 후속 목표입니다.

## Android 태블릿에 설치

**[Android APK 다운로드 — Galaxy Tab S9+ · 뒤로가기 수정판 preview.3](https://github.com/CanelE452/personal-ink-vault/releases/download/v0.1.0-preview.3/personal-ink-vault-android-preview.apk)**

1. 태블릿에서 위 **Android APK 다운로드**를 누릅니다.
2. 다운로드한 `personal-ink-vault-android-preview.apk` 파일을 열어 기존 앱 위에 **업데이트**로 설치합니다.
3. 앱을 열어 새 노트와 기존 PDF를 확인합니다. 편집기의 뒤로가기는 저장 후 문서 목록으로 돌아갑니다. PDF 가져오기에 실패하면 **PDF 가져오기 취소**를 누르고 노트 작업을 계속할 수 있습니다.
4. Drive 미연결 상태라면 왼쪽 목록의 **Drive → Google 로그인 / 재연결**을 실행합니다. 처음 연결하면 **현재 로컬 vault를 Drive에 만들기**, 이미 만든 저장소가 있으면 **기존 Drive vault 연결**을 선택합니다. [설정 안내](docs/drive-setup.md)에 자세한 순서가 있습니다.

현재 파일은 **0.1.0-preview.3 개발 미리보기 APK / 설치 번호136033**, 약 **143MB**, ARM64 지원, Android 7.0 이상용입니다. 기존 Google OAuth 등록과 같은 debug 서명을 사용합니다. 이번에는 화면·시스템 뒤로가기를 저장 후 문서 목록으로 연결했습니다. 앞선 캔버스/PDF/Drive 수정도 포함합니다. 전체 Flutter 시험258개와 분석을 통과했으며 수정판의 실제 S9+ 필기·두 기기 동기화 수용 시험은 남아 있습니다. Drive 로그인은 등록된 테스트 계정으로 진행합니다.

[릴리스·파일 목록·체크섬](https://github.com/CanelE452/personal-ink-vault/releases/tag/v0.1.0-preview.3) · [검증 기록·Windows 개발판 안내](docs/mvp-validation.md)

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

## 개발판 실행

Flutter 3.47.7/Dart 3.13.5와 Android SDK가 필요합니다. Windows 실행 파일 빌드에는 Visual Studio의 Desktop development with C++ 도구가 추가로 필요합니다. 기존 도구 경로를 현재 셸에 적용하는 `scripts/dev-tools.ps1` / `scripts/dev-tools.sh`를 제공합니다.

```text
flutter --suppress-analytics pub get
flutter --suppress-analytics test --no-pub
flutter --suppress-analytics run -d <DEVICE_ID>
```

저장소 패키지의 시험은 `packages/ink_vault_core`에서 `dart test`로 실행합니다. 첫 화면에서 오프라인 노트/PDF를 만들 수 있습니다. Android는 필기와 Markdown 열람, Windows는 필기 보기와 Markdown 편집에 집중합니다. Drive는 [별도 설정 안내](docs/drive-setup.md)에 따라 같은 Google Cloud 프로젝트의 client를 등록하고 사용자 동의를 완료해야 연결됩니다. 설정 전에도 로컬 저장은 동작합니다.

이 코드는 GPL v3인 Saber 기반입니다. 고정 소스·변경·제약은 [출처 기록](docs/upstream-provenance.md), 의존성은 [고지](THIRD_PARTY_NOTICES.md)를 참고하세요. 현재 아이콘과 전체 native/자산 감사는 배포 준비가 끝난 상태가 아닙니다.
