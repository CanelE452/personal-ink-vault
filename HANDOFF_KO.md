# Personal Ink Vault — Windows Codex 인계

**최신 수정판 — 2026-10-30:** 화면·Android 시스템 뒤로가기로 필기/Markdown 저장 후 기존 문서 목록으로 돌아가는 [preview.3](https://github.com/CanelE452/personal-ink-vault/releases/tag/v0.1.0-preview.3)를 게시했다. 소스 `0e95d71`, 앱 버전0.1.0/설치 번호136033, 기존 서명 유지. 전체 Flutter258개 통과/기존105skip/실패0, 분석0, Android 빌드43.9초/exit0과 서명·공개 다운로드 검증을 확인했다. 새 폴더 홈·생성 메뉴·Rust·Office/한글 원본 편집은 [확대 설계안](docs/library-workspace-design.md)으로 정리했으며 아직 합의 전이다. 사용자는 Rust 기업 구성 사례를 추가 질문했고 이를 공식 자료로 반영했다. 새 기능 개발·저장 형식 이전·SDK/서버 도입 전에 설계의 남은 선택을 확인한다. 이번 수정판의 실제 S9+ 실행·기기 왕복은 아직 미검증이다.

**이전 수정판 preview.2 — 2026-10-30:** S9+ 사용자 사진의 `CanvasGestureDetectorState.initState` 이전 `MediaQuery` 조회 오류를 호스트에서 재현·수정했다. PDF 실패 취소/원본 보존과 Drive 계정 복원·손상 설정 복구도 반영해 [preview.2](https://github.com/CanelE452/personal-ink-vault/releases/tag/v0.1.0-preview.2)를 게시했다. 대응 소스는 `911b3fd`, 앱 버전0.1.0/설치 번호136032이며 기존 Google 인증서 지문을 유지한다. 실제 사용자 OAuth/Drive 왕복·Windows native 실행은 계속 미검증이다. preview.1에서 처음 업데이트할 때만 Google 재연결이 필요하며, 이후 정상 연결된 앱을 업데이트할 때마다 요구하지 않는다. [오늘 기록](_docs/history/2026-10-30.md)과 [검증 기록](docs/mvp-validation.md)에 상세 결과가 있다. 개인 스크린샷은 Git 제외했다.

**추가 — 2026-10-30:** 사용자가 태블릿에서 받을 APK 공개를 요청해 [Android 미리보기 릴리스](https://github.com/CanelE452/personal-ink-vault/releases/tag/v0.1.0-preview.1)를 게시했다. README 상단은 실제 HTTPS APK 다운로드 링크다. 0.1.0/versionCode136031/debug 서명이며 기존 Google 인증서 지문을 유지한다. 실제 기기 설치·필기·OAuth 왕복 수용은 미검증이다. 아래 APK 로컬 유지 기록은 릴리스 요청 전 상태다.

## 개발 시작 — 아래 초기 기록보다 우선

사용자가 Saber·StarNote·Obsidian 조사 결과 반영과 Android·Windows·Drive MVP 개발 시작을 승인했습니다. `codex/mvp-foundation` 브랜치에 첫 검증판을 구현했습니다. 2026-10-23 최신 결과는 **기본 Flutter 237개 통과/105개 명시적 skip, 전체 분석 문제 0, Android ARM64 debug APK 빌드·서명 검증 및 Windows Release 빌드 성공**입니다. 순수 Dart 51개는 10월 22일 통과했고 이후 패키지는 변경하지 않았습니다. [검증 기록](docs/mvp-validation.md)에 산출물 해시·로그·선택 검사와 한계를 남겼습니다.

Windows C++ 도구·ATL 설치와 UTF-8 설정을 마쳤습니다. 새 Cloud 프로젝트 `personal-ink-vault`의 Drive API·Android/Web/Desktop OAuth client·본인 테스트 사용자·세 권한 범위도 등록했습니다. 두 빌드에 공개 Client ID를 포함했습니다. 다음은 Windows 실제 실행, 앱에서 본인이 하는 로그인/권한 동의 및 필요한 Desktop secret 입력, S9+↔Windows 실기기 수용 시험입니다. 실제 계정 왕복·펜/PDF 좌표·Android headless/WorkManager는 미검증입니다. 기존 구현을 처음부터 다시 시작하지 마세요. 현재 상태는 [개발 계획](docs/roadmap.md)과 [최신 기록](./_docs/history/2026-10-23.md)을 확인하세요. 아래 '앱 코드 없음/SDK 설치 없음/C++ 도구 없음'은 과거 기록입니다.

구현 원칙: Saber 편집기+완전 리비전 저장, Markdown 원문+재구축 검색 인덱스, UUID 문서/페이지 링크, Drive 불변 blob/manifest. StarNote와 Obsidian 코드를 복제하지 않습니다. 2026-10-30 사용자가 현재 개발 변경을 `main`에 commit/push하도록 승인했습니다. APK·ZIP·계정 설정은 로컬에 유지합니다. 이전 기록의 미승인 상태는 당시 기준입니다.

## 후속 결과 — 2026-10-22, 아래 초기 인계보다 우선

- 사용자 확정 MVP: Galaxy Tab S9+ PDF 필기 → Windows Markdown 정리 → Drive 자동 동기화.
- [Saber 검토](docs/saber-reuse-review.md), [설계](docs/mvp-design.md), [개발 계획](docs/roadmap.md) 작성. 전체 기반 Flutter 검증판을 권고하며 제품 채택·실기기 검증은 미완료입니다.
- [StarNote 조사](docs/starnote-investigation.md): 공식 APK 1.5.4의 Manifest·리소스·REA archive 확인. 보호 래퍼 추정이며 본체 기능/.note/Drive 동작·서명은 미검증입니다.
- REA 도구207개 노출을 확인했고 증거 export 후 세션을 닫았습니다. 아래 '도구 노출 대기/실제 호출0회'는 초기 시점의 기록입니다.
- APK·Saber 소스·REA bundle은 저장소 밖 임시 연구 폴더에 보관했습니다. 앱 코드 통합·SDK 설치·실기기·OAuth·개인자료 업로드·commit/push는 하지 않았습니다.
- 실제 펜 모델·Android/One UI 버전은 미확인입니다. GPL 기반 채택·E2E 후순위·편집 역할 제한 등 작성자 제안을 설계에 구분했습니다.

## 초기 인계 기록

기준일: 2026-10-22. 사용자는 이후 작업을 Windows Codex 앱의 `personal-ink-vault` 프로젝트에서 대화하며 진행하려고 합니다. 이 문서는 현재까지의 결과와 미확정 사항을 구분한 인계이며, 아래 계획 자체가 구현·추가 설치·배포 승인은 아닙니다.

## 목표와 필수 요구

Android StarNote로 손필기할 때 느끼는 PC 활용의 불편을 줄이고, 필기와 지식 관리를 한 앱에서 연결합니다. 개인 사용자 한 명이 Android 휴대폰·태블릿, iPhone, iPad, Windows 컴퓨터에서 사용하는 것이 목표입니다. 플랫폼 호환성은 아직 달성하거나 검증한 결과가 아닙니다.

- 펜·형광펜·지우개, 실행 취소/다시 실행, 확대·이동과 PDF 주석.
- Markdown·수식 작성 및 미리보기.
- 고정 노트 ID 기반 링크·역링크, 태그, 제목·본문 검색, 그래프. 제목을 바꿔도 연결을 유지합니다.
- 필기 원본과 분리된 AI 설명 공간. 설명이 원본 획을 덮어쓰지 않고 노트·리비전·페이지/영역을 참조하도록 설계합니다. AI 공급자와 외부 전송 방식은 미정입니다.
- 오프라인 저장·재열기와 백업·복원을 우선합니다. OCR/손글씨 검색, 그래프·AI의 첫 버전 포함 여부는 MVP 합의가 필요합니다.

iPhone의 읽기·터치·텍스트 편집과 펜 지원 태블릿의 필기 경험은 따로 검증합니다. 모든 기기에 같은 펜 하드웨어가 있다고 가정하지 않습니다.

## 확정한 코드·개인 데이터 분리

**GitHub 공개 저장소에는 앱 코드·문서와 개인정보 없는 합성 테스트 자료만 둡니다.** 실제 필기, `.note` 원본, PDF, 첨부파일, 백업, 자격증명은 올리지 않습니다. 개인 데이터의 원격 저장 대상은 비공개 Google Drive이며, 오프라인 로컬 데이터도 코드 저장소 밖에 둡니다.

Drive 로그인·OAuth grant·토큰/credentials 생성·실제 파일 업로드는 하지 않았습니다. Drive 연동, 자동 백업, 복원, 양방향 동기화도 구현하지 않았습니다. Drive에 파일을 업로드하는 기능만으로 동시 편집과 데이터 복구가 해결되는 것은 아닙니다.

- **백업/복원 후보:** 버전 있는 스냅샷을 올리고 빈 저장소로 복원하는 흐름.
- **양방향 동기화 후보:** 동시 편집 충돌, 첨부파일 중단 전송·중복·무결성, 기기 시계 차이, 삭제 표식·복원, 장기간 오프라인 기기 재합류까지 처리하는 흐름.

어느 방식으로 시작할지는 미정입니다. GitHub 코드 관리와 개인 노트 동기화는 별개이며, 동기화도 독립 백업을 대체하지 않습니다. 공개 가능한 앱 ID·OAuth client ID·리디렉션 설정과 비밀인 client secret·access/refresh token·서명 키를 구분해야 합니다. 비밀값과 계정별 설정은 Git에 넣지 않고 기기 보안 저장소 등 별도 보관 방식을 설계합니다.

## 저장소와 Windows 작업 상태

- 공개 GitHub: [CanelE452/personal-ink-vault](https://github.com/CanelE452/personal-ink-vault).
- 로컬 루트: `C:\Users\User\Documents\Codex\2026-10-22\task-4\personal-ink-vault`.
- origin: `https://github.com/CanelE452/personal-ink-vault.git`, 기본/현재 브랜치 `main`.
- 확인한 로컬 HEAD: `a38153a07f378443bc2b48a29d6c9159bd2528df`.
- 로컬 추적 ref `origin/main`도 같은 SHA입니다. 이번 인계 작성에서는 원격을 새로 fetch하지 않았으므로 실시간 원격 상태와는 구분합니다.
- 두 인계 파일 작성 직전 작업 트리는 깨끗했습니다. 이번 변경은 `START_HERE_KO.md`, `HANDOFF_KO.md` 두 미추적 파일뿐이며 stage·커밋·push하지 않았습니다. 따라서 위 SHA에는 이 두 파일이 포함되지 않습니다.

공개 저장소 생성·최초 push 및 이후 최신 상태 확인은 앞선 작업에서 완료했습니다. 최초 준비 기록에 등장하는 `6d13f1b...`는 첫 커밋이며 현재 HEAD가 아닙니다. 다음 대화에서는 이 스냅샷을 그대로 믿기보다 `git status`, 브랜치, remote와 SHA를 다시 확인하세요. 사용자 변경을 덮거나 reset/clean/force push하지 않습니다.

Windows VS Code에서 이 폴더와 README를 여는 작업은 완료했습니다. Codex 공식 프로젝트 목록에서도 다음 등록을 확인했습니다.

- 이름: `personal-ink-vault`.
- 프로젝트 ID: `7319f513-3294-454b-b341-3336fdca13e8`.
- 루트: 위 로컬 저장소와 동일, Git 저장소로 인식됨.

기존 등록을 재사용하면 됩니다. 현재 인계 작성에서 VS Code 화면을 다시 확인하거나 기존 대화의 프로젝트 이동을 검증한 것은 아닙니다. 처음 요청한 `E:\CODING\proj`는 존재하지만 실행 환경의 쓰기 허용 범위 밖이어서 그곳에 만들거나 우회 복사하지 않았습니다.

## 기존 문서 안내와 시간 순서

- [README.md](README.md): 전체 목표와 데이터 분리.
- [docs/requirements.md](docs/requirements.md): 기능 R1–R9, 데이터 원칙, StarNote 호환 단계.
- [docs/architecture-options.md](docs/architecture-options.md): PWA, Flutter/Saber, 독립 Flutter의 비교와 실기기 확인 항목.
- [docs/compatibility-research.md](docs/compatibility-research.md): 공식 출처, 플랫폼 제약, StarNote 샘플 대기 상태.
- [docs/roadmap.md](docs/roadmap.md): 제안 개발 순서와 완료 기준.
- [.gitignore](.gitignore): 개인 데이터·원본·PDF·백업·비밀정보·빌드 산출물 제외 규칙. 공개 전 파일 검토도 별도로 필요합니다.
- [_docs/history/2026-10-22.md](_docs/history/2026-10-22.md): 초기 프로젝트 준비 및 첫 push 기록.

이 문서들은 앱 준비 단계에 작성됐습니다. “스킬 URL 미제공”, “스킬 미설치”, “SDK/스킬을 설치하지 않는다”는 문구는 **REA를 지정하고 설치 승인하기 전의 범위**입니다. roadmap의 원격 생성·push 예정 표현도 당시 계획입니다. 후속 결과는 이 인계의 Git 상태와 REA 절을 함께 읽어야 합니다. 기존 문서는 이번에 수정하지 않았습니다.

## 아직 정하지 않은 기술과 MVP

PWA, Flutter/Saber 확장, Saber를 통합하지 않는 독립 Flutter 중 어느 것도 확정하지 않았습니다. 첫 비교 실험 경로를 고르는 것과 최종 기술 스택을 확정하는 것도 구분합니다.

- PWA는 공통 웹 UI·Markdown·링크를 시험하기 쉽지만, 펜 입력 품질·저장소 축출·파일 접근·백그라운드 처리의 플랫폼별 검증이 필요합니다.
- Flutter/Saber는 기존 필기 기반을 검토할 수 있지만, 통합 비용과 데이터 모델, 의존성, LICENSE 조건을 먼저 확인해야 합니다. [Saber 공식 저장소](https://github.com/saber-notes/saber)의 GPL v3와 제3자 자산·패키지 조건을 코드 통합 전에 검토합니다. Saber 코드는 아직 가져오지 않았습니다.
- 필압·기울기·팜리젝션·지연·긴 PDF·회전 페이지·중간 종료 후 복원을 실제 기기에서 비교해야 합니다. 실제 기기/OS/펜 목록과 수용 기준도 아직 없습니다.
- iOS 네이티브 빌드·서명·배포의 macOS/Xcode 환경과 유지 조건을 확인해야 합니다. Windows에서 준비했다고 iPhone/iPad 설치가 해결된 상태는 아닙니다. PWA도 iOS의 저장·백그라운드 제약을 검증해야 합니다.

첫 개발 전에 사용자와 정할 핵심 두 가지는 **첫 실험 경로와 MVP 우선순위**, **Drive의 첫 역할을 백업/복원으로 할지 양방향 동기화까지 할지**입니다. 데이터 형식·DB·Markdown/수식 엔진·AI/OCR·암호화 및 키 복구 방식도 미선정입니다.

[Obsidian 앱 자체는 무료](https://obsidian.md/pricing)이며 공식 Sync와 Publish는 선택 유료 서비스입니다. 구독이 앱 사용의 필수 조건이라는 전제는 사용하지 않습니다. 기능을 참고해 독립 구현하며 Obsidian 코드를 복제하지 않습니다.

## REA — 설치 완료, 새 대화 노출 확인은 남음

사용자가 지정한 출처는 [morluto/rea](https://github.com/morluto/rea)입니다. 전체 소스 fork 대신 **고정 버전 REA MCP와 매칭 workflow 스킬**을 사용하기로 했으며, fork는 만들지 않았습니다. 사용자 명시 승인 후 공식 `rea-agents@6.7.0`을 로컬에 설치·등록했습니다. npm 패키지의 repository 메타데이터가 해당 GitHub 저장소를 가리키는 것도 확인했습니다.

설치 경로와 등록 내용:

- 고정 런타임: `C:\Users\User\Documents\Codex\tools\rea-agents\6.7.0`.
- 실행 파일: 위 경로의 `node_modules\rea-agents\scripts\rea.mjs`.
- MCP 명령: `C:\Program Files\nodejs\node.exe`로 위 파일과 `mcp` 인자를 실행하는 로컬 **stdio** 방식.
- Codex 설정: `C:\Users\User\.codex\config.toml`의 `mcp_servers.rea`.
- 변경 전 백업: `C:\Users\User\.codex\config.toml.rea.backup`. REA 외 기존 설정이 백업과 의미상 동일함을 검증했습니다. 설정 내용이나 비밀값은 저장소에 복사하지 않습니다.
- 매칭 스킬: `C:\Users\User\.agents\skills\reverse-engineer-anything`의 `SKILL.md`와 `references` 문서 6개, 총 7개가 설치 패키지와 일치합니다.

Windows Node `24.16.0`, npm `11.13.0`이 요구 버전을 충족했습니다. 필수 의존성은 `--ignore-scripts --omit=optional`로 준비했으며, Frida·Ghidra·Hopper·JADX·JDK 등 추가 분석기는 설치하지 않았습니다. 공개 네트워크 서버나 새 credentials도 만들지 않았습니다. 처음 AppData에 준비한 복사본은 공식 경로 검사에서 등록이 거부됐고, 실제 등록에는 위 Documents 런타임만 사용합니다.

완료한 검증:

1. Codex 공식 MCP 목록에서 `rea`, enabled, stdio 및 고정 실행 경로 확인.
2. 설치된 매칭 스킬 문서 7개와 패키지 바이트 일치 확인.
3. 별도 검증 자식 서버에서 `initialize → tools/list → close` 성공. 서버 버전 `6.7.0`, **도구 목록 207개** 응답.
4. 실제 분석 도구 호출 **0회**, 분석 대상 열기 **0회**. StarNote 분석·프로세스 attach·개인 노트 수집은 하지 않았습니다. 목록 응답은 추가 분석기까지 모두 사용 가능하다는 뜻이 아닙니다.

설치 직후 진행 중이던 대화에는 REA 도구가 노출되지 않았습니다. 공식 setup은 Codex 재시작을 안내했습니다. **앱 재시작과 새 대화에서의 실제 도구 노출은 아직 검증하지 않았습니다.** 사용자 앱은 임의 종료하지 않았습니다. 다음 대화는 사용 가능한 도구 목록과 스킬 인식부터 확인하고, 노출되지 않으면 필요한 재시작을 사용자에게 안내해야 합니다. 설치를 자동 반복하지 마세요.

이 PC의 상세 근거는 [설치·연결 기록](../rea-setup-preview.md)과 [검증 결과 JSON](../rea-install-verification.json)입니다. 두 파일은 저장소 바깥의 같은 작업 공간에 있는 **로컬 전용 기록**으로, 공개 GitHub나 다른 PC의 clone에는 없습니다. 설정·백업·설치 런타임도 코드 저장소에 올리지 않습니다.

MCP 등록은 사용자 권한으로 로컬 도구를 실행할 수 있게 하는 설정입니다. 설치 승인만으로 모든 파일·프로세스 분석이 승인되는 것은 아니므로 실제 대상과 작업 범위를 별도로 정합니다.

## StarNote와 역공학의 범위

역공학은 앱 개발의 필수 선행 단계가 아닙니다. 필요한 파일 호환성과 동작 이해에 한해 범위를 정합니다. 독립 필기·Markdown 기능은 StarNote 분석 없이도 설계할 수 있습니다.

사용자 소유의 개인정보 없는 `.note` 테스트 샘플은 아직 제공되지 않았습니다. 다음은 각각 별도 완료 기준이며 **전부 미검증**입니다.

1. 원본 형식 파싱: 페이지·획·스타일·첨부 구조 읽기.
2. 보기/변환: 원본 화면과 비교한 렌더링 또는 PDF 출력.
3. 편집: 가져온 획의 개별 수정·저장·재열기.
4. 왕복 호환: 다시 만든 `.note`를 StarNote에서 정상 열기·편집.

샘플을 받으면 원본을 보호하고 저장소 밖의 읽기 전용 복사본으로 시작합니다. 앱/형식 버전과 해시, 누락 객체와 손실을 기록합니다. PDF로 변환됐다고 획 편집·왕복 호환에 성공한 것으로 표시하지 않습니다. 기존 변환기 출처는 조사 문서의 참고 단서이며 실행·호환 검증 결과가 아닙니다.

외부 코드·변환기·스킬의 LICENSE와 출처, 실행 명령, 의존성·권한·파일 접근·네트워크 전송을 먼저 검토합니다. 결제/구독·인증 우회, 라이선스 해제, 타인 데이터 추출, APK 무단 패치와 다른 앱의 라이브 파일 수집은 범위 밖입니다.

## 다음 Codex의 시작 체크리스트

- [ ] 이 파일과 START_HERE, 기존 요구사항·후보 비교·조사·로드맵을 읽고 프로젝트/상위 AGENTS.md 및 해당 스킬 지침을 확인합니다.
- [ ] 현재 폴더·Git 상태·브랜치·remote를 확인하고 사용자 변경과 이 인계의 시점 차이를 보존합니다. 기존 프로젝트 등록을 재사용합니다.
- [ ] 목표와 완료/미완료를 사용자에게 짧게 설명합니다. REA 설치와 앱 완성·StarNote 호환 완료를 구분합니다.
- [ ] 새 대화에 REA 도구와 매칭 스킬이 보이는지 확인합니다. 실제 도구 실행·attach·개인 파일 접근은 자동으로 시작하지 않습니다.
- [ ] 사용자와 첫 실험 경로, MVP 범위, Drive 백업/동기화 우선순위를 정합니다. 제안이나 미정 사항을 기존 합의로 만들지 않습니다.
- [ ] 실제 기기/OS/펜과 iOS 환경을 확인하고, 합의한 작은 범위의 입력·오프라인 저장·복원 실험부터 계획합니다. StarNote 지원이 필요하면 요구 호환 단계와 테스트 샘플을 별도로 정합니다.

현재 앱 코드·실행 파일·빌드/설치, 실기기 펜/PDF 테스트, 데이터 모델 구현, AI/OCR, Drive 연동/동기화, 백업·복원 구현, 앱/사이트 배포는 없습니다. 이번 인계 작업은 Markdown 두 파일 작성뿐이며 추가 설치·분석·커밋·push를 포함하지 않습니다. 다른 프로젝트의 목표·자료·설정은 가져오지 않습니다. Fast 라우팅은 과거 요청에 지정됐다는 정보만 있고 실제 적용 확인은 없습니다.
