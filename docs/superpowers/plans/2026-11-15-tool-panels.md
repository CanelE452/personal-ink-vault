# 223 Tool Panels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping the chosen pen, pencil, highlighter, eraser or lasso again opens a StarNote-like panel with that tool's options; stranded settings get a home; export becomes a dialog with a file name.

**Architecture:** Settings are new `PlainStow`s in `lib/data/prefs.dart`. Tools read them when they act, so a change applies to the tool already in hand (`Eraser`, `Select`, `Highlighter`). The panels are widgets in one new file shown by a `MenuAnchor` around each tool button (`consumeOutsideTap: true`), placed by the toolbar's dock edge. They replace the inline `PenModal` strip.

**Tech Stack:** Flutter (Material `MenuAnchor`, `Slider`, `SwitchListTile`, `SegmentedButton`), `stow_plain`, flutter_test.

**Spec:** `docs/superpowers/specs/2026-11-15-tool-panels-design.md`

## Global Constraints

- User-visible text is Korean, plain words, no developer terms.
- Only PDF/page notes (Saber editor) change. The infinite note keeps its own toolbar.
- No StarNote art. Use existing icons.
- Ctrl+E still toggles the eraser on and off. Only the toolbar's second tap opens the eraser panel.
- Background in export means the paper pattern (lines, grid, dots). PDF pages and pictures are always kept.
- Files keep their line endings (CRLF files stay CRLF). Write with the Edit tool, never `Path.write_text`.

## Review Focus

1. Panel open while the pen is down: an outside tap must close the panel and must not leave a stroke. `consumeOutsideTap` covers this; test it.
2. Eraser size or filter changed while the eraser is already chosen: the next erase uses the new value without choosing the tool again.
3. Rectangle lasso dragged up or left (end before start): `Rect.fromPoints` must still select.
4. Highlighter straight line with a single tap (one point): no crash, no zero-length stroke left behind.
5. Export file name with characters invalid in file names (`/`, `:`): the dialog keeps them out.

---

### Task 1: Settings and tool behaviour

**Files:**
- Modify: `lib/data/prefs.dart`, `lib/data/tools/eraser.dart`, `lib/data/tools/select.dart`, `lib/data/tools/highlighter.dart`, `lib/data/tools/pen.dart`, `lib/components/canvas/_stroke.dart`
- Test: `test/tool_panels_engine_test.dart` (new)

**Interfaces:**
- Produces:
  - `stows.eraserSize` (`PlainStow<double>`, 10), `stows.eraseHighlighterOnly` (`PlainStow<bool>`, false), `stows.highlighterStraightLine` (`PlainStow<bool>`, false), `stows.selectRectangle` (`PlainStow<bool>`, false), `stows.selectInk`, `stows.selectHighlighter`, `stows.selectImages` (`PlainStow<bool>`, true).
  - `Eraser({double? size})`: `size` reads `stows.eraserSize` when not given; `checkForOverlappingStrokes` skips non-highlighter strokes while `stows.eraseHighlighterOnly` is on.
  - `Select.onDragUpdate`: with `stows.selectRectangle` the path is `Rect.fromPoints(start, position)`. `Select.onDragEnd` keeps highlighter strokes only with `selectHighlighter`, other strokes only with `selectInk`, images only with `selectImages`.
  - `Stroke.straightenWhileDrawing()`: keeps the first and last point (snapped like `snapLine`), marks the polygon dirty, no-op under 3 points.
  - `Highlighter.onDragUpdate` calls it while `stows.highlighterStraightLine` is on.
  - `Pen.setStreamline(double value)` (0–1): saves like `setSize` (same stow per tool).

- [ ] Write tests:
  - `eraser size and highlighter-only follow the settings while the eraser is in hand`
  - `rectangle lasso selects in any drag direction and honours the type filters`
  - `straight highlighter keeps two points while drawing and survives a single tap`
  - `stroke stabilisation is saved per pen`
- [ ] Run them, see them fail. Implement. Run them, see them pass.

### Task 2: Panels

**Files:**
- Create: `lib/components/toolbar/tool_panels.dart`
- Test: `test/tool_panels_test.dart` (new)

**Interfaces:**
- Consumes: Task 1 stows, `Pen.setStreamline`, `SizePicker`.
- Produces: `PenPanel({required Pen pen, required ValueChanged<Pen> setTool, required void Function(Pen, double) setSize})`, `HighlighterPanel(...)` (same fields), `EraserPanel()`, `SelectPanel()`. Each is a fixed-width card (320) with a title (`펜`, `연필`, `형광펜`, `지우개`, `올가미`). Keys: `tool-panel-stabiliser`, `tool-panel-straight-line`, `tool-panel-eraser-size`, `tool-panel-highlighter-only`, `tool-panel-auto-release`, `tool-panel-lasso-shape`, `tool-panel-select-ink`, `tool-panel-select-highlighter`, `tool-panel-select-images`.
- Pen panel: pen types only for fountain/ballpoint/shape pen (as `PenModal`), size, stabiliser 0–100 % (hidden for the shape pen).

- [ ] Write tests: each panel shows its controls; moving a control changes its stow (or the pen's streamline); the shape pen has no stabiliser.
- [ ] Implement, pass.

### Task 3: Toolbar wiring

**Files:**
- Modify: `lib/components/toolbar/toolbar.dart`
- Test: `test/tool_panels_test.dart`, update `test/vault/editor_width_presets_test.dart` (its `SizePicker` lookup opens the pen panel first)

**Interfaces:**
- Consumes: Task 2 panels.
- Each of `pen`, `pencil`, `highlighter`, `eraser`, `select` buttons sits in a `MenuAnchor` (`consumeOutsideTap: true`); the second tap on the chosen tool calls `open()`/`close()`. The anchor opens below for a top toolbar, above for a bottom one, beside for left/right.
- `ToolOptions` keeps only `hide` and `select` (the selection bar after a lasso).
- Eraser button: not chosen → `setTool(Eraser())`; chosen → toggles its panel. `toggleEraser` (Ctrl+E) unchanged.

- [ ] Write tests: second tap opens each panel and the tool stays chosen; an outside tap closes it without a stroke; the eraser stays chosen after its second tap.
- [ ] Implement, pass, update the width-preset test.

### Task 4: Writing settings in the toolbar sheet

**Files:**
- Modify: `lib/components/toolbar/toolbar_settings_sheet.dart`
- Test: `test/toolbar_layout_test.dart` (the sheet tests live there)

- [ ] Add a `필기` heading with `거의 곧은 선을 직선으로` (`autoStraightenLines`, key `toolbar-auto-straighten`), `펜이 닿으면 손가락 그리기 끄기` (`autoDisableFingerDrawingWhenStylusDetected`), and `도형 인식` as a `SegmentedButton<int>` (500 `0.5초`, 1000 `1초`, -1 `끄기`; key `toolbar-shape-delay`). Test: each control writes its stow.

### Task 5: Export dialog

**Files:**
- Modify: `lib/components/toolbar/toolbar.dart` (export button opens the dialog), `lib/components/toolbar/export_bar.dart` (becomes `showExportDialog`), `lib/pages/editor/editor.dart` (`exportAsPdf/Sba/Png(BuildContext, {String? name, bool background = true})`), `lib/data/editor/editor_exporter.dart` (`generatePdf(..., {bool background = true})`, `screenshotPage(..., bool background = true)`)
- Test: `test/export_dialog_test.dart` (new)

**Interfaces:**
- `showExportDialog(BuildContext, {required String title, required Future Function(BuildContext, {String? name, bool background})? exportAsPdf, ... exportAsPng, ... exportAsSba})`.
- Name field (key `export-name`) starts with `customTitle ?? fileName`, strips `\ / : * ? " < > |`, falls back to the title when empty. Format `SegmentedButton` (`PDF`, `사진`, `원본 파일`; key `export-format`), `줄·격자 배경 포함` checkbox (key `export-background`, hidden for 원본 파일), `내보내기 및 공유` (key `export-go`).
- Without background the export uses `coreInfo.copyWith(backgroundPattern: .none)`.

- [ ] Write tests: default name is the note title; invalid characters are removed; the chosen format's callback gets the name and the background flag.
- [ ] Implement, pass.

### Task 6: Whole check

- [ ] `flutter analyze` on changed files, the new tests, then the 222 related list (chain_223) before the build.
- [ ] Record each change in `_docs/history/2026-11-15.md` as it lands.
