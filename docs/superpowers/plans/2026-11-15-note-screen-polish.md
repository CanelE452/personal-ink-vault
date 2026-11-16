# 노트 화면 다듬기 (219) 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 배율 알약, 끌어서 붙이는 툴바와 툴바 설정, 사람이 읽을 수 있는 오류 문구를 노트 화면에 넣는다.

**Architecture:** 공유 위젯 두 개를 만든다. 배율 알약은 `ZoomPillOverlay`, 툴바 배치는 `ToolbarDock`이다. 이 둘을 Saber 편집기(PDF·페이지)와 무한 노트가 함께 쓴다. 오류 문구는 변환 함수(`userErrorMessage`/`userErrorDetails`)와 표시 위젯 `UserErrorText` 하나로 처리한다.

**Tech Stack:** Flutter (Dart), stow prefs, flutter_test

**Spec:** `docs/superpowers/specs/2026-11-15-note-screen-polish-design.md`

## Global Constraints

- 툴바 위치는 새 저장 값 `workspaceToolbarAlignment`에 둔다. 기본값은 `AxisDirection.up`이다. Saber의 `editorToolbarAlignment`는 작업 화면에서 계속 무시한다(기존 시험 `editor_workspace_chrome_test` 유지).
- 배율 알약은 배율이 바뀔 때만 뜬다. 마지막 변화 2초 뒤 사라지고, 만지는 동안과 목록이 열린 동안에는 남는다.
- 배율 목록: 50%, 75%, 100%, 150%, 200%, 300%. PDF·페이지에서 100%는 "폭 맞춤"이다.
- 화면 문구는 한국어로 쓴다. 사용자 화면에 "PlatformException", "Exception:", "Bad state:", 앱 내부 경로가 나오면 안 된다.
- 커밋하지 않는다(사용자 규칙: 요청할 때만 커밋).

## Review Focus

1. 툴바를 끄는 도중 펜이 캔버스에 닿거나 손을 놓는 경우: 놓을 자리가 남지 않고, 획도 이상하게 남지 않아야 한다.
2. 세로 툴바가 화면보다 길 때(폰 가로·분할 화면): 도구가 잘리지 않고 다음 줄로 넘어가야 한다(Saber Wrap 동작).
3. 확대 잠금 중 배율 목록: 바뀌면 안 된다. 목록은 비활성이다.
4. 전체 화면에서 툴바를 숨기는 설정과 끌어 붙이기가 같이 있을 때: 숨김이 우선이다.
5. 오류 원문이 한국어 문장 없이 영어 개발자 문구뿐일 때: 정해 둔 한국어 문장이 나와야 한다.

---

### Task 1: 배율 알약

**Files:**
- Create: `lib/components/canvas/hud/zoom_pill.dart`
- Modify: `lib/components/canvas/hud/canvas_hud.dart` (잠금 버튼 세 개·"1.0x" 표시를 알약으로 바꾼다)
- Modify: `lib/components/canvas/canvas_gesture_detector.dart` (790–830: HUD 호출, 이동 잠금 두 개는 stows를 듣는다)
- Modify: `lib/pages/workspace/infinite_canvas.dart` (689–740 모서리 상자를 없애고, 알약을 넣고, 툴바에 "원점으로"를 둔다)
- Test: `test/components/zoom_pill_test.dart`, `test/canvas_hud_lifecycle_test.dart`, `test/workspace/infinite_canvas_test.dart`

**Interfaces:**
- Produces: `ValueListenable<double> scaleListenableOf(TransformationController c)`. 배율이 바뀔 때만 알린다.
- Produces: `ZoomPillOverlay({required ValueListenable<double> scale, ValueChanged<double>? onSelectScale, String fitLabel = '100%', bool? zoomLocked, ValueChanged<bool>? onZoomLockChanged})`. `onSelectScale`이 null이면 목록이 비활성이다.
- 키: `ValueKey('zoom-pill')`, 목록 항목 텍스트 `'50%'…'300%'`, 잠금 툴팁 `'확대 잠금'`/`'확대 잠금 풀기'`.

- [ ] 실패하는 시험 쓰기:
  - `zoom pill appears when the scale changes and hides two seconds later`: 배율 1→1.5에서 `'150%'`가 보이고, 2초와 애니메이션 시간이 지나면 투명도 0.
  - `moving without zooming does not show the pill`: 이동 행렬로만 바꾸면 알림 0회, 알약 투명도 0.
  - `choosing 200% reports scale 2`
  - `lock disables the scale list`
  - `touching the pill keeps it past two seconds`
- [ ] 실패 확인: `flutter test --no-pub test/components/zoom_pill_test.dart`
- [ ] 구현한다. `CanvasHud`는 알약만 남긴다. 생성자에서 이동 잠금 인자를 없애고 lifecycle 시험을 2초 기준으로 고친다.
  - 편집기: 배율 목록에 `setZoom`을 쓰고, 잠금 중에는 `onSelectScale: null`.
  - 무한 노트: 목록은 화면 가운데를 기준으로 확대한다. 툴바에 `'원점으로'`(Icons.my_location)를 둔다. 모서리의 `'축소'`·`'확대'` 버튼은 없앤다.
  - 무한 노트 시험 `save retains a moved view…`는 Ctrl+휠로 화면을 바꾸고, 저장 전 `viewport`와 저장값이 같은지 비교한다.
- [ ] 통과 확인: 위 세 시험 파일.

### Task 2: 끌어서 붙이는 툴바와 툴바 설정

**Files:**
- Modify: `lib/data/prefs.dart` (`workspaceToolbarAlignment` 추가)
- Create: `lib/components/toolbar/toolbar_dock.dart`
- Create: `lib/components/toolbar/toolbar_settings_sheet.dart`
- Modify: `lib/components/toolbar/toolbar.dart` (`leading` 인자 추가, Wrap 맨 앞에 둔다)
- Modify: `lib/pages/editor/editor.dart` (1523–1525 위치 선택, 1771–1795 본문 배치를 `ToolbarDock`으로, 손잡이·톱니 버튼)
- Modify: `lib/pages/workspace/infinite_canvas.dart` (`_toolbar`에 세로 배치, 손잡이·톱니, build를 `ToolbarDock`으로)
- Test: `test/components/toolbar_dock_test.dart`, `test/vault/editor_workspace_chrome_test.dart`(시험 추가), `test/workspace/infinite_canvas_test.dart`(시험 추가)

**Interfaces:**
- Produces: `AxisDirection nearestToolbarEdge(Offset local, Size size)`
- Produces: `ToolbarDock({required AxisDirection alignment, required ValueChanged<AxisDirection> onAlignmentChanged, required Widget toolbar, required Widget child})`
- Produces: `ToolbarDockHandle({Axis axis = Axis.horizontal})`. 키는 `ValueKey('toolbar-dock-handle')`, 툴팁은 `'끌어서 툴바 옮기기'`이다. 위에 `ToolbarDock`이 없으면 아무것도 그리지 않는다.
- 놓을 자리 키: `ValueKey('toolbar-dock-zone-up'|'-down'|'-left'|'-right')`
- Produces: `Future<void> showToolbarSettings(BuildContext context, {required AxisDirection alignment, required ValueChanged<AxisDirection> onAlignmentChanged, bool editorOptions = false})`. 문구는 다음과 같다.
  - 제목: `'툴바 설정'`
  - 위치 선택: `'위'`·`'아래'`·`'왼쪽'`·`'오른쪽'`
  - `editorOptions`일 때만: `'전체 화면에서도 툴바 보이기'`, `'한 손가락 이동 잠금'`, `'가로·세로로만 이동'`
- 톱니 버튼 툴팁: `'툴바 설정'`

- [ ] 실패하는 시험 쓰기:
  - `nearest edge picks the closest side`: (5,300)→left, (790,300)→right, (400,3)→up, (400,590)→down, 크기 800×600.
  - `dragging the handle to the right edge docks the toolbar there`: 끄는 동안 놓을 자리 네 개가 보인다. 놓으면 콜백이 `AxisDirection.right`를 받고 놓을 자리는 사라진다.
  - `workspace editor follows the workspace toolbar position`: `workspaceToolbarAlignment = right`이면 `Toolbar`의 첫 `Flex.direction == Axis.horizontal`.
  - `toolbar settings sheet moves the toolbar`: `'툴바 설정'` → `'오른쪽'`을 고르면 저장 값이 right가 된다.
  - `infinite toolbar docks to the left as a column`
- [ ] 실패 확인
- [ ] 구현한다. 작업 화면 편집기는 새 저장 값을, 독립 편집기는 Saber 값을 읽고 쓴다. 이동 잠금 두 개는 설정 시트에서 stows를 바꾸고, `CanvasGestureDetector`가 그 값을 듣는다.
- [ ] 통과 확인. `editor_workspace_chrome_test`와 `editor_width_presets_test`도 함께 돌린다.

### Task 3: 오류 문구

**Files:**
- Create: `lib/data/user_error.dart`
- Create: `lib/components/user_error_text.dart`
- Modify: `lib/pages/workspace/study_workspace.dart`
  - 1254: SnackBar
  - 354, 4429: 시작 오류
  - 4626·4727·4773·4867: 문서 열기 실패
  - 5142: 보관함 오류 띠
- Modify: `lib/pages/workspace/workspace_controller.dart` (71 `error`, 959·2619)
- Modify: `lib/pages/office/office_workspace.dart` (929·950·1204 `_error`, 6206 띠, 복구 경로는 자세히로)
- Test: `test/data/user_error_test.dart`

**Interfaces:**
- Produces: `String userErrorMessage(Object error)`. 오류 종류별 결과:
  - PlatformException: 메시지. 비어 있으면 `'작업을 마치지 못했습니다.'`
  - StateError: 메시지
  - `Exception: …`: 뒤 문장
  - FormatException: `'파일 내용을 읽지 못했습니다.'`
  - FileSystemException: `'파일을 읽거나 쓰지 못했습니다.'`
  - TimeoutException: `'시간 안에 끝나지 않았습니다. 다시 시도해 주세요.'`
  - String: 그대로
  - 그 밖: `'작업을 마치지 못했습니다.'`
  - 결과에 개발자 문구나 `/data/` 경로가 남으면 `'작업을 마치지 못했습니다.'`
- Produces: `String userErrorDetails(Object error)`. 원래 `'$error'`를 그대로 돌려준다.
- Produces: `UserErrorText({required String message, String? details})`. "자세히" 버튼은 `ValueKey('user-error-details')`이다.
- Produces: `void showUserErrorSnackBar(BuildContext context, Object error)`. 동작 이름은 `'자세히'`이고, 누르면 원래 오류를 대화 상자에 보여 준다.
- 컨트롤러는 `fail(Object error)`가 `error`와 `errorDetails`를 함께 정한다. `error`에 값을 직접 넣으면 `errorDetails`는 지워진다.

- [ ] 실패하는 시험 쓰기: 위 목록의 각 경우에 대한 `userErrorMessage` 결과. 그리고 `UserErrorText shows the sentence and hides the raw error until 자세히`.
- [ ] 실패 확인
- [ ] 구현하고 각 표시 지점에 적용한다. 원래 오류는 `Logger('PIVError')`로 남긴다.
- [ ] 통과 확인. 관련 작업 화면 시험(library_flow, office_workspace)을 돌려 기존 기대 문구가 그대로인지 본다.

### Task 4: 시험 전체·빌드·설치

- [ ] 관련 시험을 한 번에 돌린다. 알려진 기존 실패(`memory/piv-known-test-failures`)는 따로 표시한다.
- [ ] 218 빌드 폴더에서 219 빌드 체인을 만든다(Dart만 바뀜). 시험 → 빌드 → 점검 → 판정을 한 스크립트로 잇는다.
- [ ] 태블릿에 설치하고 설치 해시를 대조한다. 우리 앱 화면만 캡처한다.
