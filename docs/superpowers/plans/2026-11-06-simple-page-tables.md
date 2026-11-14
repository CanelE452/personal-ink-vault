# 일반 페이지 표 블록

기존 전체 Office·Obsidian·Notion·Android/Windows·Drive·Rust·MCP 목표를 유지한다. 사용자의 추가 질문 없이 진행하라는 지시에 따라, 이번 구현은 Notion 유사 페이지에 실제 표를 생성하고 편집하는 흐름을 완성한다. 다단 열·rich text·실시간 협업·전체 유료 기능 동등성을 이 작업의 완료로 대체하지 않는다. build58 후보와 기존 증거는 보존하며 commit/push·게시하지 않는다.

## 형식과 기존 데이터

새 블록은 `type:table`과 `tableData.format:personal-ink-table-1`을 함께 사용한다. `columns`는 UUID 배열이고 `rows`는 고정 UUID와 UUID/text 셀 배열을 가진다. `headerRow`와 `headerColumn`은 서식 상태다. 블록의 기존 text는 표 설명으로 유지한다. 표·행·셀의 알 수 없는 JSON 필드는 유지한다.

기존의 type:table만 있는 블록이나 다른 format은 opaque 데이터로 보존한다. 새 marker를 확인한 경우에만 해석하며, 알려진 형식의 손상된 데이터는 저장 전에 거절한다. 행1–128, 열1–32, 모든 행의 같은 셀 수, UUID 중복 금지, 셀16384자/전체 UTF-8 본문1MiB를 검증한다. 기존 페이지/미디어 snapshot·이력·Drive 저장 형식을 재사용한다.

## 구현

1. 모델은 불변 표·행·셀, 생성·셀 수정·행열 삽입/삭제·헤더 전환을 제공한다. 기존 행/셀 ID와 unknown 필드를 유지하고 최소1×1을 지킨다. Markdown 파생 표현에 실제 셀 텍스트를 포함하며 pipe·줄바꿈·HTML 문자를 이스케이프한다. 수동 summary.md는 변경하지 않는다.
2. 편집기는 생성/slash/종류 변경 메뉴에서 표를 제공한다. 기존 `_commit`의 undo/redo·dirty·저장 실패 작업본을 재사용한다. 표→텍스트 변경 때 모든 셀을 보존한다. 미지원 표를 임의의 빈 표로 바꾸지 않는다.
3. 셀은 고정 ID의 controller와 focus를 사용하고 undo/redo·문서 변경·행열 삭제에 수명을 맞춘다. 가로 스크롤과 제한 높이의 지연 행 렌더링을 사용한다. 추가·삭제·헤더 변경은 busy 상태에서 거절한다.
4. Root가 모델/widget의 실제 RED 후 구현을 승인하고 GREEN을 실행한다. 저장소 재열기·검색/Markdown projection·MCP·Drive snapshot 보존을 통합 확인한다. Android/Windows Flutter host 검사를 실기기 또는 실제 네이티브 GUI 실행이라고 표시하지 않는다.

표→문단 변환은 `tableTextConversion`의 정확한 format·정렬한 표 JSON SHA·caption·projectedText에 결합한다. 다시 표로 바꿀 때 현재 본문과 표의 fingerprint 및 실제 projection이 모두 같을 때만 원래 caption을 복원한다. 편집된 본문은 보존하고, 미래/불명 metadata를 덮어쓰지 않는다. 메뉴의 행·열 작업은 PopupMenuButton의 최신 callback을 믿지 않고 메뉴 항목 값에 열릴 당시의 표·대상 ID·index·작업을 고정한다. 현재 immutable draft와 다르면 적용하지 않는다.

## 병행 Android Office 조사

REA에서 APK의 원래 bytes와 같은 frontend5개를 정적 분석하고 증거를 보존했다. native symbols는 NDK의 실제 ELF reader로 확인했다. 전역 executeScript와 현재 문서 getter·명령 wire는 존재하지만 Android의 실제 JSUNO 표/셀 binding과 저장은 아직 실행 검증하지 못했다. inspect 반환 전에 문서가 닫힌다는 수명 제약을 유지한다. 이번 표 블록은 Office 원본의 표 편집 권위를 대신하지 않는다.

## 검증 체크포인트

runtime665/84587a4a…에서 전체 Flutter1779PASS/108skip/0FAIL·분석0, 표 및 기존 미디어84PASS, 실제 Study2·Rust stdio1·disk remote 동기화6개를 확인했다. 실제 SDK2프로세스 자연 종료0이며 고정 ID·opaque/media·기존 판본·별도 Markdown·stale/permission/invalid/retry 가드를 포함한다. 자세한 입력·실패·로그는 `build/validation/simple-page-tables1/checkpoint1.json`에 있다. 새 소스의 설치 묶음과 실제 기기/계정 수용·전체 남은 범위는 아직 완료하지 않았다.

이후 동일665소스를 Windows59·Android136059로 빌드하고 E의 candidate59-1에 별도 포장했다. 새 표 marker가 양쪽 AOT에 있고 실제 새 Release SDK 표1·Study6·DLL9·DB 미디어1·Office21·PPT 셀1/새 표1과 CRC/서명/JNI/라이선스를 확인했다. 포장2/exit0이며 이전 묶음은 보존했다. 실제 기기/계정·GUI·외부 모델 및 전체 남은 요구는 계속 미완료다. 최신 파일·해시는 HANDOFF와 README를 따른다.
