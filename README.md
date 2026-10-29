# Personal Ink Vault

개인 PDF 필기와 Markdown 정리를 연결하는 Flutter 앱입니다. **첫 MVP는 Galaxy Tab S9+ PDF 필기 → Windows에서 필기를 보며 Markdown 정리 → Drive 자동 동기화**입니다. iPhone·iPad는 후속 목표입니다.

## 실행·설치 바로가기

아래 링크는 **이 PC에 만들어 둔 로컬 파일**을 엽니다. 빌드 파일은 Git에 포함하지 않으므로 GitHub 웹에서는 다운로드 링크로 동작하지 않습니다.

- [Windows 실행 파일](C:/Users/User/Documents/Codex/2026-10-22/task-4/personal-ink-vault/build/windows/x64/runner/Release/personal_ink_vault.exe) — 같은 폴더의 DLL·data와 함께 사용합니다.
- [Windows 전체 ZIP](C:/Users/User/Documents/Codex/2026-10-22/task-4/personal-ink-vault/build/validation/personal-ink-vault-windows-x64.zip) — 압축을 풀고 `personal_ink_vault.exe`를 실행하세요.
- [Android APK](C:/Users/User/Documents/Codex/2026-10-22/task-4/personal-ink-vault/build/app/outputs/flutter-apk/app-debug.apk) — Galaxy Tab S9+에 전달해 설치하세요.
- [Drive 로그인·동기화 설정 안내](C:/Users/User/Documents/Codex/2026-10-22/task-4/personal-ink-vault/docs/drive-setup.md)

## 프로젝트 현황

Saber 고정 소스 기반 검증판과 자체 불변 저장·Drive 모듈을 개발 중입니다. 세 앱 분석을 반영한 [설계](docs/mvp-design.md), [개발 현황](docs/roadmap.md), [검증 기록](docs/mvp-validation.md)을 먼저 확인하세요. 코드 시험 통과와 실기기·실제 Drive 왕복 검증은 구분합니다.

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
