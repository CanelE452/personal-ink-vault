# Drive 연결 설정과 검증

이 검증판은 Google Cloud 프로젝트나 OAuth 자격 증명을 자동 생성하지 않는다. 로그인 전에도 로컬 vault를 사용할 수 있다. Google 로그인·2단계 인증·권한 동의는 본인이 진행한다. 먼저 합성 노트만 있는 시험 vault를 사용한다.

2026-10-22~23 후속 작업에서 새 프로젝트 `personal-ink-vault`의 Drive API, External Testing, Android/Web/Desktop client 3개, 본인 테스트 사용자 1명과 아래 세 범위를 등록했다. 사용자가 Google 정책 동의를 직접 완료했다. **앱의 실제 Google 로그인·권한 동의·Drive 왕복은 아직 미실행**이다.

공개 Client ID는 Git 제외 `build/validation/oauth-client-ids.json`에 있으며 새 Windows Release/Android debug 빌드에 해당 플랫폼 ID를 기본값으로 넣었다. 기존에 앱에서 저장한 설정은 빌드 기본값보다 우선한다. 이전 저장값이 비어 있거나 다른 ID라면 Drive → OAuth 설정에서 이 파일의 해당 공개 ID를 입력한다. Windows client 보안 비밀은 Console 생성창을 남겨 두었으므로 필요하면 본인이 앱의 가려진 secret 필드에 직접 입력한다. 보안 비밀을 포함한 다운로드 파일의 실제 저장 위치는 확인하지 않았으며, 이 공개 ID 파일에는 secret/token이 없다.

## Google Cloud

1. [Google Cloud Console](https://console.cloud.google.com/)에 로그인하고 두 기기에서 사용할 **하나의 프로젝트**를 선택한다. 해당 프로젝트의 API Library에서 **Google Drive API**를 활성화한다.
2. Google Auth Platform → **Branding**에서 앱 이름 `Personal Ink Vault`, 본인의 지원·연락 이메일을 설정한다. **Audience**는 개인 Google 계정이라면 External을 선택하고 Testing 상태로 준비한다. **Audience → Test users → Add users**에 두 기기에서 로그인할 Google 계정을 등록한다. Google 정책 동의나 본인 확인이 표시되면 직접 내용을 확인하고 진행한다.
3. **Data Access → Add or Remove Scopes**에서 `https://www.googleapis.com/auth/drive.file`, `openid`, `https://www.googleapis.com/auth/userinfo.email`을 준비한다. 앱은 Windows 로그인 때 `openid email`과 Drive 범위를 요청한다. 전체 Drive 접근 범위는 추가하지 않는다.
4. **Clients → Create client**에서 아래 Android 등록, Android용 Web client, Windows용 Desktop app client를 모두 같은 프로젝트에 만든다. 이미 동일 package·인증서·용도로 등록된 client가 있다면 재사용한다. 세 client를 서로 다른 Cloud 프로젝트로 나누지 않는다.

```text
Client 용도              유형              Console 등록 / 앱 입력
Android APK 인증         Android           package + 서명 SHA-1 등록
Android 로그인 서버 ID   Web application   Web client ID를 Android 앱에 입력
Windows 로그인           Desktop app       Desktop client ID를 Windows 앱에 입력
```

Client ID는 공개 식별자다. Desktop client secret과 access/refresh token은 채팅에 보내거나 저장소, `.env`, 명령행 `--dart-define`, 로그, 노트 백업에 넣지 않는다. Desktop secret 입력이 필요하면 본인이 앱의 가려진 입력 필드에 직접 넣는다.

동의 화면의 실제 메뉴와 계정 등록은 [Google 공식 설정 안내](https://developers.google.com/workspace/guides/configure-oauth-consent)를 따른다. 같은 프로젝트의 client를 하나의 앱으로 취급하는 원칙은 [Cross-client Identity](https://developers.google.com/identity/protocols/oauth2/cross-client-identity)에 설명돼 있다.

Drive의 파일별 권한과 동의 범위는 [Drive 인증 안내](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)를 따른다. 두 플랫폼 client가 같은 앱으로 만든 vault를 함께 열 수 있는지는 실제 계정 왕복으로 확인해야 한다. 아직 이 검증판에서 실증하지 않았다. 목록이 비어도 전체 Drive 권한으로 자동 확대하지 않는다.

## Android

태블릿에서 왼쪽 노트 목록 하단의 **Drive**를 누른다. 목록이 접혀 있으면 왼쪽 위 메뉴 버튼으로 먼저 연다. 업데이트 뒤에는 **Google 로그인 / 재연결**을 한 번 직접 실행한다. 이전 버전은 복원에 필요한 계정 식별자를 저장하지 않았으므로 기존 로그인만으로 자동 복원되지 않는다.

Google Cloud에서 Android OAuth client를 등록한다. Package name은 `io.github.canele452.personalinkvault`이다. 실제 설치할 APK를 서명한 인증서 SHA-1을 등록한다.

[확인] 이 PC에서 빌드한 debug APK의 공개 서명 인증서 SHA-1을 `apksigner verify --print-certs`로 확인했다. 아래 값은 비밀 키나 토큰이 아닌 인증서 지문이다.

```text
Package: io.github.canele452.personalinkvault
SHA-1:   33:BB:30:7D:54:91:EA:5E:43:AE:0C:D3:3C:F1:3A:B4:E2:B5:C8:77
```

같은 debug 키로 빌드한 APK에 사용한다. 다른 PC·다른 서명 키의 APK를 설치하면 그 APK의 지문을 다시 확인한다. 개발 debug keystore 확인 예시는 다음과 같다.

```powershell
keytool -list -v -keystore "$HOME/.android/debug.keystore" -alias androiddebugkey -storepass android -keypass android
```

Linux에서는 같은 명령의 경로를 `"$HOME/.android/debug.keystore"`로 사용한다. Debug keystore가 아직 없다면 첫 debug APK 빌드로 만들어진 뒤 확인한다. Release 키나 다른 개발 PC의 키를 쓰면 그 인증서의 SHA-1도 별도로 등록한다. 키 파일을 저장소에 복사하지 않는다.

같은 프로젝트에 **Web application** OAuth client도 만든다. 앱의 Drive → OAuth 설정에 이 **Web client ID**를 입력한다. Android client ID를 이 필드에 넣지 않는다. `google-services.json` 없이 `GoogleSignIn.initialize(serverClientId: ...)`를 사용하는 구성이다. Gradle Google Services 플러그인이나 Firebase 프로젝트는 이 경로에 필요하지 않다.

Android에서 Web client ID를 변경한 뒤에는 **설정 저장 → 앱 완전 종료 → 다시 실행 → Google 로그인 / 재연결** 순서로 진행한다. 현재 Google Sign-In singleton은 같은 Flutter engine에서 다른 serverClientId로 재초기화할 수 없다. 홈 화면으로 이동했다가 복귀하는 것만으로는 앱 프로세스가 종료되지 않을 수 있다.

이 구분과 SHA·package·serverClientId 오류는 Flutter 공식 [google_sign_in_android 설정](https://pub.dev/packages/google_sign_in_android)에 근거한다. 로그인/권한 요청은 사용자 버튼에서만 시작한다. 기존 인증의 noninteractive token 요청이 실패한 백그라운드 작업은 재로그인 필요 상태를 기록하고 로컬 전송 큐를 보존한다.

수동 로그인·권한 승인 성공 후 계정 ID·이메일·공개 Web client ID를 OS 보안 저장소에 기록한다. 자동 복원과 백그라운드 작업은 이 계정을 지정하고 `promptIfUnauthorized: false`로 토큰을 요청한다. 앱 시작 시 계정 선택창을 자동으로 열지 않으며 access token을 앱 파일에 영구 저장하지 않는다. 권한이 취소됐거나 설정이 다르면 재연결이 필요하다. 이 경로의 플랫폼 호출 회귀시험과 실제 기기 인증 성공은 별개다.

설정을 읽지 못해도 Drive 창에서 오류를 확인하고 **설정 다시 읽기**를 누를 수 있다. 손상이 반복되면 **연결 설정 복구 → 원본 보관 후 복구**로 연결 정보만 초기화한다. 원본은 `drive/connection-backup-<고유값>/connection.json`에 보관하고 로컬 노트·PDF·Drive 자료·보안 저장 계정은 유지한다. 복구 자체는 로그인·폴더 생성·업로드를 실행하지 않는다. 이후 Google 로그인 후 **기존 Drive vault 연결**을 선택한다. Google 오류에는 진단용 코드만 표시하고 원문 응답·토큰은 표시하지 않는다.

## Windows

같은 프로젝트에 **Desktop app** OAuth client를 만든다. Drive → OAuth 설정에서 Desktop client ID를 입력한다. Google이 해당 client에 secret을 요구하면 Console에서 받은 값을 선택 필드에 입력한다. 값은 Flutter Secure Storage의 Windows 저장소에만 저장하며, 빈 필드는 기존 값을 유지한다. `client_secret`은 provider 문서상 선택 필드이고, desktop 앱은 secret을 완전히 비밀로 유지할 수 있는 client로 간주되지 않는다.

로그인 버튼은 시스템 브라우저를 연다. 무작위 verifier의 S256 PKCE, 무작위 state, `127.0.0.1`의 임시 포트와 단일 callback을 사용한다. Callback은 host·path·GET·state·중복 query를 확인한다. 3분 만료 또는 앱의 로그인 취소 버튼으로 종료된다. Callback URL, code, token을 화면/로그에 출력하지 않는다. Refresh token 저장이 실패하면 로그인 완료로 처리하지 않는다. 만료한 access token은 저장된 refresh token으로 갱신한다.

Provider의 [Desktop OAuth 흐름](https://developers.google.com/identity/protocols/oauth2/native-app)과 [토큰 만료 안내](https://developers.google.com/identity/protocols/oauth2#expiration)를 참고한다. **External + Testing 프로젝트에서 `drive.file`을 포함해 발급받은 refresh token은 7일 후 만료된다.** 따라서 시험 중 7일 뒤 재로그인이 필요할 수 있다. 앱은 로컬 노트·전송 큐를 유지하고 재연결을 안내해야 한다. 실제 반복 재로그인도 시험한다.

## 본인이 직접 진행할 부분

1. Cloud Console의 Google 로그인과 2단계 인증을 완료한다. 사용할 프로젝트·연락 이메일·테스트 계정을 본인 계정 기준으로 선택하고 정책 동의가 나오면 확인한다.
2. 위 절차대로 같은 프로젝트의 Android/Web/Desktop 세 client를 준비한다. 앱에 입력할 공개 값은 Android용 **Web client ID**와 Windows용 **Desktop client ID** 두 개다. Desktop secret이 필요하면 앱에 직접 입력하고 채팅에는 보내지 않는다.
3. 각 기기의 앱에서 **Drive → OAuth 설정 → 설정 저장 → Google 로그인 / 재연결**을 연다. 두 기기에서 같은 Google 계정을 고르고 Drive 파일 권한을 직접 허용한다. Windows의 로그인·동의 화면은 3분 안에 끝내고, 만료되면 앱에서 다시 시작한다.
4. 첫 기기의 합성 시험 vault만 Drive에 만들고 둘째 기기에서 그 vault를 선택한다. S9+ 필기 → Windows 수신, Windows Markdown → S9+ 수신을 확인한다. 실제 왕복이 확인되기 전에는 개인 원본 PDF를 시험 자료로 사용하지 않는다.

로그인과 권한 동의를 마쳐도 두 기기에서 같은 vault가 보이고 수정이 왕복하는 것까지 확인해야 연결 검증이 끝난다. 문제가 생기면 오류 문구·단계만 공유하고 callback URL·authorization code·token은 공유하지 않는다.

## 앱에서 연결

1. Drive → OAuth 설정 저장 → Google 로그인 / 재연결을 누른다. 계정 선택과 동의를 완료한다.
2. 첫 기기에서는 **현재 로컬 vault를 Drive에 만들기**를 선택한다. 폴더 생성 전에 사전 발급 fileId를 앱 설정에 기록하므로 응답을 잃어도 같은 ID로 재시도한다.
3. 두 번째 기기는 **기존 Drive vault 연결**에서 같은 vault를 선택한다. 기존 로컬 vault의 ID를 바꾸지 않고 app-support의 별도 `vaults/drive-<vaultId>`를 연다. 저장하지 않은 편집이 있으면 먼저 저장한다.
4. 연결 해제는 계정/원격 연결과 저장된 refresh token을 제거한다. 로컬 노트는 삭제하지 않는다. 다른 계정으로 로그인한 상태에서 이전 계정의 cached folder로 자동 전송하지 않는다.

공개 ID만 빌드에 제공할 수도 있다. 앱에서 저장한 설정이 있으면 저장된 값을 우선한다.

```text
flutter run -d android --dart-define=DRIVE_ANDROID_SERVER_CLIENT_ID=<WEB_CLIENT_ID>
flutter run -d windows --dart-define=DRIVE_DESKTOP_CLIENT_ID=<DESKTOP_CLIENT_ID>
```

`android`는 연결한 기기의 실제 ID로 바꿀 수 있다. 비밀 값은 위 인자에 넣지 않는다.

## 실행과 백그라운드 경계

실행 중에는 저장 debounce와 15초 polling으로 송수신하고, 전경 복귀 시 디스크 저장소를 다시 열어 백그라운드 수신 내용을 재구성한다. 편집 중인 작업본과 세션 부모 리비전은 workspace에서 보존한다. Windows 앱 종료 중 동기화는 지원하지 않는다.

Android는 WorkManager의 연결된 네트워크 조건, 일회성 재시도와 15분 주기 작업을 등록한다. OS 강제중지·절전·배터리 정책·headless 인증 제한 때문에 실행 시각을 보장하지 않는다. [Workmanager 공식 quickstart](https://docs.page/fluttercommunity/flutter_workmanager/quickstart)와 [Android persistent work 안내](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)를 참고한다. 백그라운드 작업은 독립 repository/coordinator를 열고 항상 닫는다.

전경/백그라운드 전송은 app-support에 기록한 loopback TCP port의 배타적 bind로 직렬화한다. 수신 payload는 없고 연결은 즉시 닫는다. Android isolate 간에는 POSIX 파일 lock이 배타성을 제공하지 않기 때문에 이 lease를 사용한다([Dart lock 문서](https://api.dart.dev/dart-io/RandomAccessFile/lock.html)). 다른 프로세스가 같은 포트를 점유하면 전송을 멈추고 재시도를 표시한다. 노트 파일을 자동 삭제하거나 lock 파일을 강제로 지우지 않는다.

연결 설정과 폴더 생성 intent는 app-support `drive/connection.json`, 계정별 전송 상태는 `drive/state/<folderId>/`, 마지막 background 상태는 `drive/background-status.json`에 있다. 이 파일들은 Git이나 노트 백업에 넣지 않는다. Desktop refresh token·선택 secret과 Android 복원용 계정 식별자는 OS 보안 저장소에만 둔다. Android credential은 Google의 native SDK가 관리한다.

## 실제 기기 수용 시험 — 아직 미실행

- S9+에서 합성 PDF/필기 저장 → 앱 종료 → 재열기 → 네트워크 복구 → Windows의 같은 vault 수신과 blob SHA-256 비교.
- Windows Markdown 수정 → Android 수신, 시계 차이·동시 수정·삭제/오프라인 수정 충돌 보존.
- 로그인 취소, 테스트 사용자 미등록, SHA 불일치, 권한 거부, refresh 만료, secure storage 실패에서 로컬 자료와 큐 보존.
- Android 전경/백그라운드 전환 중 동시 전송 차단, 프로세스 종료 후 lease 회복, OS 제한 시 상태의 정직한 표시.

단위시험은 실제 OAuth 동의, 서로 다른 platform client의 Drive 접근, S9+ 백그라운드 SDK 동작을 대체하지 않는다.

## 로컬 개발 도구 경로

기존 PATH를 사용하거나, 현재 shell에만 도구 경로를 추가한다. 아래 경로는 실제 설치 위치로 바꾼다. 레지스트리·shell profile·전역 PATH를 수정하지 않는다.

```powershell
. ./scripts/dev-tools.ps1 -FlutterRoot '/path/to/flutter' -AndroidSdkRoot '/path/to/android-sdk' -JavaRoot '/path/to/jdk'
```

```bash
. ./scripts/dev-tools.sh /path/to/flutter /path/to/android-sdk /path/to/jdk
```

두 스크립트의 경로 인자는 선택 사항이다. Ubuntu에서 Windows `.ps1`을 사용하거나 드라이브 문자를 복사하지 않는다. Windows 빌드에는 별도로 Visual Studio C++ desktop 도구가 필요하다.
