# Personal Ink Vault Android 196 대응 소스

[Android 196 APK 바로 다운로드](https://github.com/CanelE452/personal-ink-vault/releases/download/v0.2.0-android.196/personal-ink-vault-android-0.2.0-build196-136196-arm64-release.apk)

이 스냅샷은 Android `io.github.canele452.personalinkvault` 버전 `0.2.0`의 설치 번호 `136196`에 대응합니다. `SOURCE-MANIFEST.json`에 파일별 SHA-256과 Git 모드를 기록했습니다. APK와 버전 안내는 [Android 196 릴리스](https://github.com/CanelE452/personal-ink-vault/releases/tag/v0.2.0-android.196)에서 받으세요.

앱 소스와 프로젝트 빌드 스크립트의 배포 조건은 [GNU GPL v3](LICENSE.md)에 따릅니다. 개별 구성 요소의 출처와 조건은 [제3자 고지](THIRD_PARTY_NOTICES.md)에 있습니다.

## Android ARM64 빌드

1. Flutter `3.47.7`의 [고정 소스](https://github.com/flutter/flutter/tree/abaf9c523780a608bd46686fd5e53740a07077f8), Dart `3.13.5`, JDK `25.0.4.1+1`, Android SDK 및 Python 3.11 이상을 준비합니다. Flutter SDK가 래퍼를 준비하고 `android/gradle/wrapper/gradle-wrapper.properties`에서 Gradle `9.5.0`을 선택합니다. Gradle 데몬에는 저장소의 JVM 설정에 따라 JetBrains JDK 21을 자동으로 준비하거나 기존 설치를 사용합니다.
2. Android SDK의 `platforms;android-37.0`, `ndk;28.2.13676358`, `ndk;29.0.14206865`, `cmake;3.22.1`을 준비합니다. Rust `1.99.1`에 `aarch64-linux-android` 타깃을 추가합니다. Android SDK 경로를 `ANDROID_SDK_ROOT`로 지정하세요.
3. 소스 루트에서 `bash scripts/build-android-196.sh`를 실행합니다. Android Gradle 작업이 두 Rust 라이브러리, 한글 렌더링·내보내기 글꼴, Office Android 라이브러리를 준비합니다. 출처는 Cargo 잠금 파일, 글꼴 manifest 및 [Office 엔진 잠금 파일](android/office_engine/engine.lock.json)에서 확인할 수 있습니다.
4. 사용자 본인의 서명 키로 설치용 APK를 만들려면 `android/key.properties`에 `storeFile`, `storePassword`, `keyAlias`, `keyPassword`를 로컬로 지정합니다. 서명 전 빌드만 하려면 이 파일 없이 빌드할 수 있습니다. 본인의 OAuth 공개 클라이언트 ID로 테스트하려면 `DRIVE_ANDROID_SERVER_CLIENT_ID`를 설정합니다.

스크립트는 ARM64의 빌드 번호를 `136196`로 지정합니다. 공개 APK는 유지관리자의 기존 서명 키와 공개 OAuth 클라이언트 설정을 사용합니다. 로컬 재빌드는 키와 빌드 환경에 따라 APK 바이트가 달라질 수 있습니다.

## 고정된 업스트림 소스

- Office Android Java·C++ 및 편집기 웹 리소스는 [Collabora Online 고정 리비전](https://github.com/CollaboraOnline/online.mirror/tree/fd0b24ba59e043b2ed9087eb6324bbc6d281e93b)에서 확인할 수 있습니다. [엔진 준비 스크립트](android/office_engine/prepare_engine.py)는 잠금 파일의 공식 APK와 소스 파일 해시를 확인하고, 앱의 Android 통합에 필요한 변경을 적용합니다. 자세한 내용은 [Office 소스 안내](android/office_engine/README.md#source-and-notices)에 있습니다.
- PDFium의 기본 Android 네이티브 배포물은 Flutter 의존성의 빌드 훅에서 받습니다. [PDFium 고정 소스 계열](https://pdfium.googlesource.com/pdfium/+/refs/heads/chromium/7811)과 [Android PDFium 빌드 스크립트](scripts/build_pdfium.sh)를 이용할 수 있습니다.
- 한글 처리 라이브러리는 [hwp-cli 고정 리비전](https://github.com/STAIxBWLB/hwp-cli/tree/4e6e8c2a61694899e37b4f7c2f97523153a623b9)과 [Cargo 잠금 파일](packages/ink_hwp_native/Cargo.lock)에 연결됩니다.
- Dart 의존성은 [pubspec.lock](pubspec.lock), 공통 Rust 엔진은 [Cargo.lock](packages/ink_vault_native/Cargo.lock)을 사용합니다.

Android 아이콘 원본은 `assets/icon/`의 세 SVG입니다. 변경 후 `python scripts/generate_android_icons.py`로 PNG를 다시 만들 수 있습니다. 동일한 렌더러를 사용하려면 `PyMuPDF==1.28.2` 및 `Pillow==12.0.0`을 설치하세요.
