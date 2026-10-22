# 호환성 조사

조사일: 2026-10-22. **문서 확인**은 공식 자료를 읽었다는 뜻이며 실기기·성능·변환 성공을 뜻하지 않습니다. 앱/변환기/스킬은 설치·실행하지 않았습니다.

## Obsidian 기능 참고

Obsidian 앱은 개인·상업 사용 모두 무료이고 공식 Sync는 선택 유료입니다. 이 프로젝트의 목적은 필기와 PC 활용을 원하는 방식으로 결합하는 것이며, Obsidian 사용에 구독이 필수라는 전제는 사용하지 않습니다. [공식 가격과 FAQ](https://obsidian.md/pricing)

링크·역링크·검색·태그·그래프·Markdown 요구를 자체 모델로 구현합니다. 앱 무료 사용과 코드 재사용 허가는 다르므로 Obsidian 코드·바이너리를 복제하지 않습니다. [공식 약관](https://obsidian.md/terms)

## PWA 입력·보관·백그라운드

- Pointer Events는 펜 종류·압력·기울기를 표현합니다. 압력 미지원 환경에서 기본값이 반환될 수 있으므로 API 존재만으로 필압 지원을 판단하지 않습니다. 팜리젝션과 사용자 체감 지연도 보장되지 않습니다. [W3C Pointer Events](https://www.w3.org/TR/pointerevents3/)
- Safari 18.2 공식 발표에는 병합/예측 이벤트와 펜 각도 API 지원이 포함됩니다. iOS 전체가 이를 미지원한다고 단정하지 않고 최소 OS·브라우저와 기능 탐지를 검증합니다. [WebKit Safari 18.2](https://webkit.org/blog/16301/webkit-features-in-safari-18-2/)
- Safari 17/iOS 17부터 Storage API를 지원하며 기본 저장은 best-effort입니다. 저장 공간 압박 등에 따른 데이터 축출, 영구 저장 요청 승인 여부, 실제 용량 부족에 대비해야 합니다. 홈 화면 설치도 독립 백업의 대체물이 아닙니다. [WebKit 저장 정책](https://webkit.org/blog/14403/updates-to-storage-policy/)
- OPFS는 origin 전용 저장소입니다. 사용자 파일 앱의 일반 폴더와 같다고 가정하지 않습니다. Chromium 파일 선택/폴더 쓰기 기능도 모든 브라우저에 동일하게 존재하지 않으므로 가져오기·내보내기 경로가 필요합니다. [WebKit OPFS](https://webkit.org/blog/12257/the-file-system-access-api-with-origin-private-file-system/), [Chrome 파일 접근](https://developer.chrome.com/docs/capabilities/web-apis/file-system-access)
- 서비스 워커는 상주 프로세스가 아니며 종료될 수 있습니다. Background Sync도 플랫폼 공통 전제로 삼지 않고 앱 재실행·전경 복귀 시 재시도해야 합니다. Safari 지원 상태는 개발 시 다시 확인합니다. [서비스 워커 수명](https://web.dev/learn/pwa/service-workers#service_worker_lifespan), [Edge Background Sync](https://learn.microsoft.com/en-us/microsoft-edge/progressive-web-apps/how-to/background-syncs), [WebKit 구현 요청](https://bugs.webkit.org/show_bug.cgi?id=182565)

판단: PWA는 비교할 가치가 있는 후보입니다. 필기감과 데이터 보존에 대한 실기기 증거는 아직 없으며 채택 결정은 보류합니다.

## Flutter / Saber

[Saber 공식 저장소](https://github.com/saber-notes/saber)는 공개 Flutter/Dart 프로젝트입니다. 공식 설치 안내에는 Android·iOS·Windows 등 배포 경로가 있습니다. 이는 우리 확장 앱의 모든 기능이 호환된다는 증거가 아닙니다. [프로젝트 의존성](https://github.com/saber-notes/saber/blob/main/pubspec.yaml), [설치 안내](https://github.com/saber-notes/saber/wiki/install)

공개 편집기에는 필기 도구와 PDF 가져오기/내보내기 코드가 있습니다. PDF 배경 가져오기와 기존 PDF 주석의 편집 객체 복원은 구분해야 합니다. 네이티브 `.sbn2`/구형 `.sbn` 구조를 공개 코드에서 검토할 수 있지만 안정된 외부 표준으로 가정하지 않습니다. [편집기 소스](https://github.com/saber-notes/saber/blob/main/lib/pages/editor/editor.dart), [내보내기 소스](https://github.com/saber-notes/saber/blob/main/lib/data/editor/editor_exporter.dart)

현재 LICENSE는 GPL v3입니다. 통합 전 기준 커밋과 파일별 조건을 기록하고, 적용 범위·고지 보존·변경 표시·배포 시 대응 소스 제공 조건을 검토합니다. 제3자 의존성·자산·상표도 별도 대상입니다. 개인 사용/비공개 저장소라는 이유만으로 모든 조건을 생략하거나 공개 배포 의무를 단정하지 않습니다. 이번에는 코드를 복사하거나 라이선스를 채택하지 않았습니다. [실제 LICENSE](https://github.com/saber-notes/saber/blob/main/LICENSE.md)

## iPhone / iPad 네이티브 설치와 펜

- Flutter 공식 iOS 빌드/배포 경로는 macOS와 Xcode를 요구합니다. Windows에서 문서·공통 코드 준비를 시작하는 것과 iOS 바이너리 빌드/설치는 별도입니다. [Flutter iOS 가이드](https://docs.flutter.dev/deployment/ios)
- 유료 가입이 모든 개인 기기 테스트에 필수인 것은 아닙니다. 무료 Apple Account의 Xcode Personal Team 경로가 있지만 프로비저닝은 7일 후 만료되어 재빌드·재설치가 필요합니다. 지원 기능·기기 수 제한 및 재설치 시 데이터 보존/복원을 확인해야 합니다. [Apple 계정 안내](https://developer.apple.com/help/account/basics/about-your-developer-account)
- TestFlight 빌드는 최대 90일 시험용이므로 영구 개인 설치 방식으로 가정하지 않습니다. 배포 경로·유지 비용·빌드 환경은 선택 전 확인 대상입니다. 이번에 계정 가입·서명·배포를 하지 않습니다. [Apple TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- 펜의 기기 호환과 압력 지원을 모델별로 확인합니다. Apple Pencil USB-C처럼 압력을 지원하지 않는 모델도 있으므로 펜 이름만으로 필압을 약속하지 않습니다. [Apple Pencil 비교](https://www.apple.com/apple-pencil/)

## StarNote `.note` — 샘플 대기

사용자 소유 테스트 샘플이 없습니다. 파싱→보기/변환→편집→왕복 네 단계는 전부 미검증이며 포맷 해석 완료로 표시하지 않습니다. 필요한 표본은 빈 노트, 압력 변화가 있는 획, 형광펜/지우개, PDF 위 주석, 회전/다중 페이지 등 개인정보 없는 최소 사례입니다. 허용된 샘플만 저장소 밖에서 다룹니다.

사용자 제공 [변환기 개발자 주소](https://yiwei-zheng.github.io/)는 참고 단서입니다. 이번 직접 재조회에서는 404가 반환되어 현재 상세 설명을 재확인하지 못했습니다. 변환기 프로젝트를 실행 검증하지 않았고, 지원 범위·완성도·라이선스는 확인 전입니다. 변환 결과가 PDF여도 원본의 개별 획 편집이나 StarNote 재저장이 가능하다는 뜻은 아닙니다.

샘플 수령 후 읽기 전용 복사본의 형식·앱 버전·해시를 기록하고 구조/기존 공개 설명부터 비교합니다. 삭제·숨김·알 수 없는 객체는 임의로 해석하거나 버리지 않고 손실 보고서 대상으로 둡니다. 다른 앱의 라이브 파일을 수집하지 않습니다.

## 역공학 스킬이 필요한가

이번 요구사항/공식 자료 조사에는 별도 역공학 스킬이 필요하지 않았습니다. 특정 GitHub 스킬 URL도 제공되지 않았습니다. 필요하다면 먼저 사용자 소유 샘플의 읽기 전용 형식 분석으로 해결 가능한지 확인합니다.

향후 스킬이나 변환기를 도입하기 전 코드·실행 명령·파일 접근·네트워크 전송·요청 권한·의존성과 LICENSE를 검토합니다. 신뢰성 검토 없이 설치/실행하지 않습니다. 구독·인증 우회, 타인 자료 추출, APK 무단 패치는 범위 밖입니다.

실기기 검증 항목과 다음 결정은 [후보 비교](architecture-options.md)와 [개발 계획](roadmap.md)에 있습니다.
