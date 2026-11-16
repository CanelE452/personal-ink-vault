# 224 도구 패널 2차 구현 계획

> 실행: 223과 같이 이 세션에서 직접 구현하고(Native), 끝에 새 리뷰어 한 명이 전체를 본다.

**목표:** 펜·형광펜·지우개 패널을 StarNote 화면 구조로 다시 짓고, 원형 선택 지우기·형광펜 수평/수직·펜박스·종류별 색 기억·펜 버튼의 연필을 넣는다.

**설계:** `docs/superpowers/specs/2026-11-15-tool-panels-v2-design.md`

**기술:** Flutter, stow 설정값(`lib/data/prefs.dart`), perfect_freehand 획, 223 `ToolPanelAnchor`.

## 전역 제약

- 줄바꿈 유지: CRLF 파일(eraser.dart, select.dart, _stroke.dart, editor.dart, toolbar.dart, study_workspace.dart)은 CRLF, 나머지는 LF.
- 새 저장값은 모두 `volatile: !_isOnMainIsolate`.
- 그림·아이콘은 우리 것(CustomPainter, Material Symbols). StarNote 자산 금지.
- 223 테스트 키 유지: `tool-panel-stabiliser`, `tool-panel-straight-line`, `tool-panel-eraser-size`, `tool-panel-highlighter-only`, `tool-panel-auto-release`, `tool-panel-lasso-shape`, `tool-panel-select-*`, `tool-panel-$id`.
- 노트 저장 형식은 바꾸지 않는다(선 종류·끝 모양은 225).

## 검토 초점

1. 원형 선택 지우기 중 두 손가락이 닿으면(확대) 지우기가 일어나지 않아야 한다 → 끄는 동안에는 아무것도 지우지 않고 뗄 때만 지운다.
2. 지운 뒤 실행 취소 한 번에 모두 돌아와야 한다 → `.erase` 기록 하나.
3. 펜박스 칸의 굵기가 그 펜 범위 밖이면(예전 값) 앱이 멈추면 안 된다 → `setSize` 전에 범위로 자른다.
4. 연필을 고른 뒤 다른 노트를 열어도 펜 버튼이 연필이어야 한다 → `stows.lastPenFamily`.
5. 형광펜 색이 앱을 다시 열어도 남아야 한다 → `Highlighter()`가 저장값을 읽는다.

---

### 작업 1: 엔진 — 종류별 색, 펜 묶음, 수평·수직, 원형 선택 지우기

파일: `lib/data/prefs.dart`, `lib/data/tools/pen.dart`, `lib/data/tools/highlighter.dart`, `lib/data/tools/eraser.dart`, `lib/components/canvas/_stroke.dart`, `lib/pages/editor/editor.dart`, `lib/components/canvas/canvas.dart`, `lib/components/canvas/_canvas_painter.dart`, 테스트 `test/tool_panels_engine_test.dart`

인터페이스:
- `stows.lastPenFamily: PlainStow<ToolId>` (기본 fountainPen), `stows.highlighterAxisLock: PlainStow<bool>`, `stows.eraserMode: PlainStow<EraserMode>`, `stows.penBox: PlainStow<List<String>>`.
- `Pen.setColor(Color)`: 색을 바꾸고 그 종류의 `last…Color`에 쓴다. `static Pen get currentPenFamily`: 연필이면 `Pencil.currentPencil`, 아니면 `Pen.currentPen`.
- `Stroke.straightenWhileDrawing({bool axisLock = false})`.
- `enum EraserMode { stroke, lasso }`. `Eraser.lassoPath`, `Eraser.lassoPageIndex`, `startLasso(Offset, int)`, `extendLasso(Offset)`, `List<Stroke> finishLasso(List<Stroke>)`.
- 캔버스: 지우개 올가미는 `currentSelection`으로 넘기고 `selectionErases: true`면 error 색으로 그린다.

테스트:
- 원형 선택이 안쪽 70% 이상인 획만 고르고, 형광펜만 지우기를 따른다.
- 수평·수직: (0,0)→(100,20)은 (100,0), (0,0)→(10,80)은 (0,80).
- `Pen.setColor` 뒤 새 `Pen.fountainPen()`이 그 색, 새 `Highlighter()`가 저장된 형광펜 색.

### 작업 2: 펜박스 데이터

파일: 새 `lib/data/tools/pen_box.dart`, 테스트 `test/tool_panels_engine_test.dart`

인터페이스: `PenBoxEntry(toolId, color, size, streamline)`, `PenBoxEntry.of(Pen)`, `Pen createPen()`(굵기는 범위로 자름), `PenBox.entries`, `PenBox.add(entry) -> bool`(최대 20, 중복 거절), `PenBox.remove(entry)`.

테스트: 같은 펜 두 번 추가 → 1개, 범위 밖 굵기 칸 → 범위 안 펜, JSON 왕복.

### 작업 3: 패널 위젯과 펜 그림

파일: 새 `lib/components/toolbar/pen_drawings.dart`(펜 그림, 펜 받침대), `lib/components/toolbar/tool_panels.dart`(다시 짓기), 테스트 `test/tool_panels_test.dart`

인터페이스:
- `PenTray(items, selected, color, onSelected)`, 항목 키 `pen-type-<id>`.
- `PenPanel(getPen, setTool, setSize, setColor, openColors)`, `HighlighterPanel(같음)`, `EraserPanel()`, `SelectPanel()`, `PenBoxPanel(apply)`.
- 키: `tool-panel-line-solid|dashed|dotted`, `tool-panel-size`, `tool-panel-size-value`, `tool-panel-color-<i>`, `tool-panel-add-to-pen-box`, `tool-panel-axis-lock`, `tool-panel-eraser-mode-pixel|stroke|lasso`, `pen-box-entry-<i>`, `pen-box-remove-<i>`.

테스트: 펜 패널에서 연필 고르기, 두께 mm 표시, 색 칸, 펜박스 추가 후 펜박스에서 고르기, 지우개 원형 선택 카드.

### 작업 4: 툴바

파일: `lib/components/toolbar/toolbar.dart`, `lib/components/toolbar/toolbar_layout.dart`, 테스트 `test/toolbar_layout_test.dart`, `test/tool_panels_test.dart`

- 펜 버튼 = 펜 묶음(선택 표시·아이콘), 연필 항목 기본 숨김, `penBox` 항목(별 버튼 + 패널), 형광펜일 때 파스텔 빠른 색, 패널을 버튼 가운데 아래에.

### 작업 5: 검증과 기록

- 관련 테스트 → 체인(경로 첫 테스트·문서 테스트 포함) → 빌드 → 설치 전 확인 → 태블릿 화면을 참고 10·12·13번과 대조.
- `_docs/history/2026-11-15.md`, `_docs/history/.pending.md`, `_docs/notes/starnote-tools.md`.
