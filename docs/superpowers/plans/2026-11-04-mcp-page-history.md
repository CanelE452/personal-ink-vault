# MCP 페이지 이력 비교·복원

사용자의 전체 앱 개발·MCP 편집 요구를 계속한다. 기존 build49의 앱 이력 화면에 연결된 실제 저장 계층을 MCP에서도 사용한다. 전체 Office/Notion 동등성과 실제 S9+/두 기기 검증은 이 계획만으로 완료되지 않는다.

## 범위와 계약

- 읽기 도구 `compare_page_revision`: noteId, 과거 revisionId, 비교할 현재 본문 expectedRevisionId, 선택 offset/limit. 저장된 본문만 읽고 전체 차이를 계산한 뒤 최대100행·256KiB payload 예산으로 반환한다. 메타데이터/폴더 조상을 포함한 exact expectedHeads를 함께 돌려준다.
- 쓰기 도구 `restore_page_revision`: 위 세 ID, 비교 결과의 expectedHeads, requestId. 기존 `document_action.restore`는 계속 휴지통 복원이다.
- `list_revisions`에 선택 body target 및 페이지 이동을 추가한다. 새 인자를 모두 생략하면 기존 전달 및500개 기본 응답을 유지한다.
- 본문 비교는 page.json만1MiB까지 읽는다. 관련 없는 첨부를 열지 않는다. 복원은 선택한 판본의 전체 파일·baseRefs를 보존한다.
- 준비 판본 ID와 exact guards를 공개 전에 요청 영수증에 저장한다. 재시작·공개 후 응답 유실·완료 영수증 기록 실패에도 같은 requestId로 같은 판본을 확인한다. 이후 판본이 생겼다면 과거 성공을 확인하되 새 판본이나 세션 부모를 되돌리지 않는다.
- 현재 MCP 쓰기 권한은 최종 manifest rename 직전에도 검사한다. 다른 저장소·위조 소유권·누락 guards·변경된 요청은 거부한다.

## 작업 순서

- [x] Core: 준비 판본의 엄격한 descriptor 재개, 선택 파일 읽기. 새 RED 시험 후 구현·전체 core142PASS.
- [x] Domain: immutable 복원 계획, 정확한 역사적 binding 검증, snapshot 시점의 metadata/조상 guards와 최종 권한 검사. 기존 UI 복원과 pending 정책 유지.
- [x] Rust SDK: 실제 stdio discovery16도구, 닫힌 typed schemas, compare 읽기/restore 쓰기 allowlist, omission 호환. 전체24PASS/clippy0.
- [x] App MCP: readonly 비교·크기/페이지 제한, version2 복원 영수증, 동일 요청 재개, 기존 version1 미완료 요청은 계속 unknown. UI 활성 문서 갱신 연결.
- [x] 통합: 실패 경계·재시작·소유권·권한/metadata/folder/body race, 실제 stdio→앱→저장소, Study 재열기 검증. focused170PASS/1skip, 전체1043PASS/108skip/0FAIL·분석0.
- [x] 검토·회귀·분석·두 플랫폼 빌드·설치된 MCP/native 검증 후 build50 로컬 묶음 승격. 설치16PASS·DLL9PASS·무결성45PASS. README/인계/기록 갱신. commit/push/게시·외부 AI 전역 설정 변경 없음. 전체 앱 목표는 계속 미완료다.

## 실행 기록

- 2026-11-04: 세 worker의 시험 작성 완료. Root가 모든 실행·빌드 담당. Core RED는 새 API 미구현으로 exit1이다.
- 첫 SDK RED 래퍼는 Flutter toolchain만 활성화하고 Cargo 경로를 설정하지 않아 시험 미실행이었다. 이 결과를 제품 RED로 세지 않으며 portable Rust 경로를 명시한 별도 red2 실행을 남긴다.
- 변경 중인 기존 작업 트리와 역사적 증거를 유지한다. 새 core descriptor는 인증 토큰이 아니며 domain/요청 영수증의 소유권·digest 결합 검증을 대체하지 않는다.
- App 서비스는 새 기능 부재12RED 뒤 구현했다. 실제 old MCP 실행 파일의14≠16 실패도 남겼으며 새 release MCP를 빌드했다. Study1000/320px에서 앱 이력 복원과 MCP 복원 후 편집기 갱신을 통과했다. 최종 통합 gate는 아래 후속 결과를 따른다.
- 두 reviewer가 같은 actual-manifest 캐시 누락을 찾았다.6개 disk 손상/삭제 RED 후 공통 acknowledgement에 실제 manifest 대조를 추가했다. 과거 성공을 확인할 때 후속 writer parent는 되감지 않는다.
- 첫 서비스/stdio 시험의 import/base class/return type fixture compile 오류와 focused2의 잘못된 파일 경로, focused3의 기존 sheet mock protocol 누락은 별도 실패 로그로 유지한다. 제품 RED나 성공으로 바꾸지 않는다.
- 실제 디스크를 확인하는 ack 뒤 반환의 await와 기존 lint11건을 정리한 현재 source에서 전체 앱1043PASS/108skip/0FAIL(5분5초), 분석0(7.1초)이다. source600파일 SHA `79283031d86ce795309503db0b082dfe6997a1d78826c39bccf94623d1ec7fa0`. core142개·SDK24개도 최종 재실행했고 fresh core 검토에서 추가 P1/P2는 없었다. 두 플랫폼 빌드·묶음 검증은 다음 gate다.
