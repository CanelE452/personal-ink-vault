import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/audio/record_pill.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/components/ink_ui/editor_toolbar/toolbar_tools_layout.dart';
import 'package:saber/components/ink_ui/tool_panels/kit_lasso_panel.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_menu.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_toolbar.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/ink/ink_engine.dart';
import 'package:saber/data/prefs.dart';

/// Sizes of the 9th draft c bar not in [KitTokens].
abstract final class _Bar {
  /// A chosen tool's icon (`--app-bar`).
  static const selectedInk = KitTokens.editorToolbarSelectedInk;

  /// A button whose window is open: white 18 %.
  static const openFill = KitTokens.editorToolbarOpenFill;

  /// The writing/gesture button's inner ring: 1.5, white 50 %.
  static const modeRing = KitTokens.editorToolbarModeRing;
  static const modeRingWidth = 1.5;

  /// The thin line after the writing/gesture button: 7 from each button
  /// (`margin 0 4px` + the gap 3), of which the buttons' taps take 1.5.
  static const sepMargin = 7 - KitTokens.toolbarGroupGap / 2;

  /// Each button takes taps over the gap beside it and the bar's height
  /// (values §12-4 #9: 37 × 46), so the visible button stays 34.
  static const hitWidth = KitTokens.toolbarButton + KitTokens.toolbarGroupGap;

  /// The bar's windows: 6 under the bar, rows 44 (values §14-5).
  static const windowGap = 6.0;
  static const layoutTop = 112.0;
  static const moreWidth = 236.0;
  static const docWidth = 224.0;
}

/// The editor toolbar (preview 9th draft c, user 2026-11-25): 쪽 목록 and
/// 노트 창 at the start; the writing/gesture switch, a thin line, the tools
/// the user keeps on the bar (1 to 6) and ⌄ in the middle; 노트 추가,
/// 전체 화면 and ⋯ at the end. The middle slides sideways when the bar is
/// too narrow.
///
/// It runs the document's actions and draws them as they are now. The pen
/// and the eraser buttons also show and hide the floating bar
/// ([floatingBarOpen]); pressed again with their tool in hand they only do
/// that. The lasso has no floating bar: chosen, its button shows a small ⌄
/// and its icon the lasso kind, and pressed again it opens 「올가미 선택」
/// under it (10th draft). The note window button opens and closes
/// [noteSheetOpen]. Gesture mode is `stows.editorGestureMode`. ⋯ opens the
/// document menu ([buildDocMenu]). Where the document publishes 녹음, its
/// button ends the middle past a thin line (12th draft `tbHtml`), with a red
/// mark while [recording] says it records (grey paused); when it starts, a
/// middle that slides moves to show it. 노트 추가 runs the document's window
/// action (lit while it is open), which hangs from [insertPageAnchor].
///
/// A host with its own few tools (the infinite note, Task 18) gives them in
/// [tools]: they stay on the bar in that order, with no ⌄. Without
/// [noteSheetOpen] there is no note window button, and with [docMenu] off
/// no ⋯. The end shows the infinite note's 「원점으로」 and 「저장」 when the
/// document publishes them. Such a bar keeps the editor's places (Task 18
/// fix 2): its start as wide as the editor's 쪽 목록 and, where [noteSlot],
/// 노트 창, its end as 노트 추가 · 전체 화면 · ⋯, and its middle as the
/// editor's with the user's tools and ⌄, so the tools both have stand at the
/// same x.
class KitEditorToolbar extends StatefulWidget {
  const new({
    super.key,
    required this.actions,
    required this.title,
    required this.floatingBarOpen,
    this.noteSheetOpen,
    this.floatingBarFrom,
    this.pages,
    this.zoom,
    this.tools,
    this.docMenu = true,
    this.engine = InkEngineSupport.editor,
    this.recording,
    this.recordSlot = false,
    this.noteSlot = true,
    this.insertPageAnchor,
  });

  final AppActionRegistry actions;

  /// The document's name, on top of the ⋯ window.
  final String title;

  final ValueNotifier<bool> floatingBarOpen;
  final ValueNotifier<bool>? noteSheetOpen;

  /// Set to where across the screen the middle of the pen or eraser button
  /// is when it shows or hides the floating bar (it grows from there).
  final ValueNotifier<double?>? floatingBarFrom;

  /// The page on screen and the number of pages, read when ⋯ opens (for
  /// 「쪽 N」 and 「쪽으로 이동」).
  final ({int index, int count}) Function()? pages;

  /// The page area's zoom, for 「확대 비율」 in ⋯.
  final DocZoom? zoom;

  /// The tools on the bar, in order; null: the user's layout, the others
  /// under ⌄.
  final List<ToolbarTool>? tools;

  /// Whether ⋯ shows.
  final bool docMenu;

  /// What the document's ink engine has: 「올가미 선택」 shows its targets.
  final InkEngineSupport engine;

  /// Whether a recording runs: the record button's mark.
  final ValueListenable<KitRecording>? recording;

  /// On a bar with its own [tools]: whether the editor's bar there would
  /// end its middle with the record button, so the tools stand where the
  /// editor's do.
  final bool recordSlot;

  /// On a bar with its own [tools]: whether the editor's bar there would
  /// show 노트 창 (its vault keeps the quick note, format 2).
  final bool noteSlot;

  /// Under 노트 추가, as wide as it: where its window hangs from.
  final GlobalKey? insertPageAnchor;

  @override
  State<KitEditorToolbar> createState() => _KitEditorToolbarState();
}

class _KitEditorToolbarState extends State<KitEditorToolbar> {
  final _moreAnchor = GlobalKey();
  final _docAnchor = GlobalKey();
  final _lassoAnchor = GlobalKey();

  /// Under ⌄, for 「올가미 선택」 while the lasso is kept there.
  final _moreLassoAnchor = GlobalKey();

  /// The pen and the eraser buttons, which show the floating bar.
  final _barButtons = {'pen': GlobalKey(), 'eraser': GlobalKey()};

  final _recordButton = GlobalKey();

  /// The [KitEditorToolbar.recording] the bar was last built with.
  var _built = KitRecording.off;

  /// The width the middle was last laid out in.
  double? _middleWidth;

  /// The ⌄, ⋯ or lasso window open now ('more', 'doc', 'lasso'), drawn on
  /// its button.
  String? _open;

  AppActionRegistry get _actions => widget.actions;

  /// The pen button stands for every pen kind: the fine-nib pen, the fine
  /// pen, the pencil and the highlighter.
  bool _checked(ToolbarTool tool) {
    bool on(String id) => _actions.lookup(id)?.checked ?? false;
    if (tool.id == 'pen') {
      return on(AppActionIds.toolPen) ||
          on(AppActionIds.toolHighlighter) ||
          on(AppActionIds.toolPencil);
    }
    return on(tool.action);
  }

  /// A tool button (or its row in ⌄): back to writing from gesture mode;
  /// the pen or the eraser in hand shows or hides the floating bar, the
  /// lasso in hand opens its window, any other press takes the tool up, with
  /// the floating bar for the pen and the eraser (사진 and another tool in
  /// hand pressed again leave the bar as it is).
  void _press(ToolbarTool tool) {
    final gesture = stows.editorGestureMode.value;
    final inHand = _checked(tool);
    final hasBar = tool.id == 'pen' || tool.id == 'eraser';
    if (gesture) stows.editorGestureMode.value = false;
    if (hasBar) _barFrom(tool.id);
    if (inHand) {
      if (hasBar) {
        widget.floatingBarOpen.value = gesture || !widget.floatingBarOpen.value;
        return;
      }
      // leaving gesture mode with the tool already in hand
      if (gesture) return;
      if (tool.id == 'lasso') {
        unawaited(_openLasso());
        return;
      }
    }
    _actions.run(tool.action, context);
    // 사진 (its picker may be cancelled) and the text box pressed off take
    // no other tool up: the bar stays as it was
    if (inHand || tool.action == AppActionIds.pickPhoto) return;
    widget.floatingBarOpen.value = hasBar;
  }

  /// Tells [KitEditorToolbar.floatingBarFrom] the middle of button [id].
  void _barFrom(String id) {
    final box =
        _barButtons[id]?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    widget.floatingBarFrom?.value = box
        .localToGlobal(box.size.center(Offset.zero))
        .dx;
  }

  /// 「올가미 선택」 under the lasso button, or under ⌄ when the lasso is
  /// kept there (도구 막대 사용자화), kept on the screen: taller than the
  /// room under the toolbar, it slides inside.
  Future<void> _openLasso() async {
    final screen =
        Navigator.of(context).context.findRenderObject() as RenderBox?;
    final onBar = _lassoAnchor.currentContext != null;
    widget.engine.keepTargetsOn();
    setState(() => _open = onBar ? 'lasso' : 'lassoMore');
    await showKitPopover<void>(
      context: context,
      anchor: onBar ? _lassoAnchor : _moreLassoAnchor,
      shadows: KitTokens.menuShadow,
      border: false,
      nub: true,
      within: screen,
      builder: (_) => KitLassoPanel(engine: widget.engine),
    );
    if (mounted) setState(() => _open = null);
  }

  /// Opens the ⌄ or ⋯ window; with [within] (the screen) a longer one
  /// stays under the bar and slides inside.
  Future<void> _openWindow(
    String which,
    GlobalKey anchor,
    KitMenu Function() menu, {
    RenderBox? within,
  }) async {
    setState(() => _open = which);
    await showKitMenu(
      context: context,
      anchor: anchor,
      builder: menu,
      within: within,
    );
    if (mounted) setState(() => _open = null);
  }

  /// Closes the window (and its submenu, [depth] 2), then [then].
  void _closeThen(VoidCallback then, {int depth = 1}) =>
      closeMenuThen(context, then, depth: depth);

  KitMenu _moreMenu() {
    final layout = _layout();
    return KitMenu(
      width: _Bar.moreWidth,
      window: true,
      groups: [
        KitMenuGroup(
          title: '막대에 없는 도구',
          rows: [
            for (final id in layout.hiddenIds)
              if (_actions.lookup(toolbarToolOf(id).action) != null)
                KitMenuRow.action(
                  key: ValueKey('editor-more-$id'),
                  icon: toolbarToolOf(id).icon,
                  label: toolbarToolOf(id).label,
                  onTap: () => _closeThen(() => _press(toolbarToolOf(id))),
                ),
          ],
        ),
        KitMenuGroup(
          rows: [
            if (_actions.has(AppActionIds.toolbarCustomize))
              KitMenuRow.action(
                key: const ValueKey('editor-toolbar-customize'),
                icon: KitIconName.tune,
                label: '도구 막대 사용자화',
                onTap: () => _closeThen(
                  () => _actions.run(AppActionIds.toolbarCustomize, context),
                ),
              ),
          ],
        ),
      ],
    );
  }

  KitMenu _docMenu() {
    final pages = widget.pages?.call() ?? (index: 0, count: 0);
    return buildDocMenu(
      context: context,
      title: widget.title,
      actions: _actions,
      pageIndex: pages.index,
      pageCount: pages.count,
      zoom: widget.zoom,
      width: _Bar.docWidth,
      layoutTop: _Bar.layoutTop,
    );
  }

  ToolbarToolsLayout _layout() => ToolbarToolsLayout.read(
    stored: stows.editorToolbarTools.value,
    stored229: stows.pageToolbarLayout.value,
  );

  @override
  Widget build(BuildContext context) {
    // A fixed size, so its changes lay out and paint the bar alone, never
    // the page beside it.
    return SizedBox(
      width: double.infinity,
      height: KitTokens.toolbarHeight,
      child: RepaintBoundary(
        child: ListenableBuilder(
          listenable: Listenable.merge([
            _actions,
            stows.editorToolbarTools,
            stows.pageToolbarLayout,
            stows.editorGestureMode,
            stows.selectRectangle,
            ?widget.noteSheetOpen,
            ?widget.recording,
          ]),
          builder: (context, _) => _bar(),
        ),
      ),
    );
  }

  /// A tool's button. The lasso shows its kind and, chosen, the ⌄ of the
  /// window it opens.
  Widget _toolButton(ToolbarTool tool, bool enabled, bool gesture) {
    final selected = !gesture && _checked(tool);
    final lasso = tool.id == 'lasso';
    return _BarButton(
      key: ValueKey('editor-tool-${tool.id}'),
      icon: toolbarToolIcon(tool, lassoRect: stows.selectRectangle.value),
      tooltip: tool.label,
      selected: selected,
      dropdown: lasso && selected,
      open: lasso && _open == 'lasso',
      centreAnchor: lasso ? _lassoAnchor : null,
      onPressed: enabled ? () => _press(tool) : null,
    );
  }

  /// [onLabel] names it while its action is on (full screen: the way out).
  /// With [busyNotDimmed], while its action is on it takes no press but is
  /// drawn whole: a state, not a switched-off button (the infinite note's
  /// 「저장 중」 clock, final review design call 3).
  Widget _actionButton(
    String id,
    String key,
    String label, {
    String? onLabel,
    bool busyNotDimmed = false,
    bool openWhenChecked = false,
    GlobalKey? centreAnchor,
  }) {
    final action = _actions.lookup(id);
    if (action == null) return const SizedBox.shrink();
    final on = action.checked ?? false;
    return _BarButton(
      key: ValueKey(key),
      icon: action.icon,
      tooltip: on ? onLabel ?? label : label,
      onPressed: action.enabled ? () => _actions.run(id, context) : null,
      dimmed: busyNotDimmed && on ? false : null,
      open: openWhenChecked && on,
      centreAnchor: centreAnchor,
    );
  }

  /// The thin line after the writing/gesture button and before 녹음.
  Widget _line(Key key) => SizedBox(
    width: 2 * _Bar.sepMargin + KitTokens.toolbarDividerWidth,
    child: Center(
      child: SizedBox(
        key: key,
        width: KitTokens.toolbarDividerWidth,
        height: KitTokens.toolbarDividerHeight,
        child: const ColoredBox(color: KitTokens.toolbarDividerColor),
      ),
    ),
  );

  /// A recording started: the middle slides to the record button, centred
  /// or as near as it goes (`scrollTo(mid, rec)`).
  void _showRecordButton() {
    final button = _recordButton.currentContext;
    if (!mounted || button == null) return;
    unawaited(Scrollable.ensureVisible(button, alignment: 0.5));
  }

  Widget _bar() {
    final gesture = stows.editorGestureMode.value;
    final recording = widget.recording?.value ?? KitRecording.off;
    bool runs(KitRecording r) =>
        r == KitRecording.on || r == KitRecording.paused;
    if (recording != _built) {
      if (runs(recording) && !runs(_built)) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _showRecordButton(),
        );
      }
      _built = recording;
    }
    final noteSheet = widget.noteSheetOpen;
    final tools =
        widget.tools ??
        [for (final id in _layout().shownIds) toolbarToolOf(id)];
    final start = [
      // lit while the left panel is open (12th draft `.b.open`)
      _actionButton(
        AppActionIds.pageList,
        'editor-page-list',
        '쪽 목록',
        openWhenChecked: true,
      ),
      if (noteSheet != null)
        _BarButton(
          key: const ValueKey('editor-note-sheet'),
          icon: KitIconName.noteUp,
          tooltip: '노트 창',
          open: noteSheet.value,
          onPressed: () => noteSheet.value = !noteSheet.value,
        ),
    ];
    final middle = [
      _BarButton(
        key: const ValueKey('editor-mode'),
        icon: gesture ? KitIconName.palm : KitIconName.draw,
        tooltip: gesture ? '제스처 모드' : '필기 모드',
        ring: true,
        // a screen publishes `gestureMode`; a bar built alone flips the stow
        onPressed: () {
          if (!_actions.run(AppActionIds.gestureMode, context)) {
            stows.editorGestureMode.value = !gesture;
          }
        },
      ),
      _line(const ValueKey('editor-mode-line')),
      for (final tool in tools)
        if (_actions.lookup(tool.action) case final action?)
          KeyedSubtree(
            key: _barButtons[tool.id],
            child: _toolButton(tool, action.enabled, gesture),
          ),
      if (widget.tools == null)
        _BarButton(
          key: const ValueKey('editor-tools-more'),
          icon: KitIconName.chev,
          tooltip: '도구 더 보기',
          open: _open == 'more' || _open == 'lassoMore',
          anchor: _moreAnchor,
          centreAnchor: _moreLassoAnchor,
          onPressed: () => _openWindow('more', _moreAnchor, _moreMenu),
        ),
      // not on a bar with its own tools (the infinite note)
      if (widget.tools == null)
        if (_actions.lookup(AppActionIds.record) case final record?) ...[
          _line(const ValueKey('editor-record-line')),
          KeyedSubtree(
            key: _recordButton,
            child: _BarButton(
              key: const ValueKey('editor-record'),
              icon: KitIconName.mic,
              tooltip: record.label,
              mark: switch (recording) {
                KitRecording.on => KitTokens.recMarkOn,
                KitRecording.paused => KitTokens.recMarkPaused,
                KitRecording.off || KitRecording.saving => null,
              },
              onPressed: record.enabled
                  ? () => _actions.run(AppActionIds.record, context)
                  : null,
            ),
          ),
        ],
    ];
    final end = [
      _actionButton(
        AppActionIds.insertPageMenu,
        'editor-insert-page',
        '노트 추가',
        openWhenChecked: true,
        centreAnchor: widget.insertPageAnchor,
      ),
      _actionButton(
        AppActionIds.fullscreen,
        'editor-fullscreen',
        '전체 화면',
        onLabel: '전체 화면 끝내기',
      ),
      _actionButton(AppActionIds.canvasOrigin, 'editor-canvas-origin', '원점으로'),
      _actionButton(
        AppActionIds.canvasSave,
        'editor-canvas-save',
        '저장',
        onLabel: '저장 중',
        busyNotDimmed: true,
      ),
      if (widget.docMenu)
        _BarButton(
          key: const ValueKey('editor-doc-menu'),
          icon: KitIconName.more,
          tooltip: '문서 메뉴',
          open: _open == 'doc',
          anchor: _docAnchor,
          anchorRightAligned: _Bar.docWidth,
          onPressed: () => _openWindow(
            'doc',
            _docAnchor,
            _docMenu,
            within:
                Navigator.of(context).context.findRenderObject() as RenderBox?,
          ),
        ),
    ];
    final fixed = widget.tools != null;
    // the editor's middle: 필기/제스처, the line, the user's tools and ⌄,
    // and where it records the line and 녹음
    final editorMiddle =
        _Bar.hitWidth +
        2 * _Bar.sepMargin +
        KitTokens.toolbarDividerWidth +
        (_layout().shownIds.length + 1) * _Bar.hitWidth +
        (widget.recordSlot
            ? 2 * _Bar.sepMargin + KitTokens.toolbarDividerWidth + _Bar.hitWidth
            : 0);
    final toolRow = Row(mainAxisSize: MainAxisSize.min, children: middle);
    return Material(
      color: KitTokens.toolbarBg,
      child: SizedBox(
        height: KitTokens.toolbarHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: KitTokens.toolbarPadding - KitTokens.toolbarGroupGap / 2,
          ),
          child: Row(
            children: [
              if (fixed)
                SizedBox(
                  width: (widget.noteSlot ? 2 : 1) * _Bar.hitWidth,
                  child: Row(children: start),
                )
              else
                Row(mainAxisSize: MainAxisSize.min, children: start),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // narrowed or widened while it records (the device
                    // turned): the record button is shown again
                    if (constraints.maxWidth != _middleWidth) {
                      if (_middleWidth != null && runs(recording)) {
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _showRecordButton(),
                        );
                      }
                      _middleWidth = constraints.maxWidth;
                    }
                    return SingleChildScrollView(
                      key: const ValueKey('editor-tools-scroll'),
                      scrollDirection: Axis.horizontal,
                      clipBehavior: Clip.hardEdge,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: constraints.maxWidth,
                        ),
                        // the editor's middle centred, or from the start when
                        // it slides; a fixed bar's tools from its start
                        child: !fixed
                            ? Center(child: toolRow)
                            : editorMiddle <= constraints.maxWidth
                            ? Center(
                                child: SizedBox(
                                  width: editorMiddle,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: toolRow,
                                  ),
                                ),
                              )
                            : Align(
                                alignment: Alignment.centerLeft,
                                child: toolRow,
                              ),
                      ),
                    );
                  },
                ),
              ),
              if (fixed)
                SizedBox(
                  width: 3 * _Bar.hitWidth,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: end,
                  ),
                )
              else
                Row(mainAxisSize: MainAxisSize.min, children: end),
            ],
          ),
        ),
      ),
    );
  }
}

/// One bar button: 34 × 34 drawn, taps over 37 × 46. White icon; chosen,
/// a white fill and the dark blue icon; [open] (its window is open), white
/// 18 %; [ring], the writing/gesture switch's inner ring; [dropdown], 40
/// wide with a small ⌄ after the icon (`.tb .b.dd`). A window opens from
/// [anchor], 6 under the bar, at the button's left, or with its right edge
/// on the button's when [anchorRightAligned] gives the window's width;
/// [centreAnchor] is as wide as the button, 6 under it, for a window
/// centred under it. Without [onPressed] it is dimmed, unless [dimmed] says
/// otherwise. [mark] draws the recording mark in its top right.
class _BarButton extends StatelessWidget {
  const new({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.dimmed,
    this.selected = false,
    this.open = false,
    this.ring = false,
    this.dropdown = false,
    this.anchor,
    this.anchorRightAligned,
    this.centreAnchor,
    this.mark,
  });

  final KitIconName icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool? dimmed;
  final bool selected;
  final bool open;
  final bool ring;
  final bool dropdown;
  final GlobalKey? anchor;
  final double? anchorRightAligned;
  final GlobalKey? centreAnchor;
  final Color? mark;

  @override
  Widget build(BuildContext context) {
    const size = KitTokens.toolbarButton;
    const side = (_Bar.hitWidth - size) / 2;
    final width = dropdown ? KitTokens.toolbarDropdownWidth : size;
    final enabled = onPressed != null;
    final shape = BorderRadius.circular(KitTokens.toolbarButtonRadius);
    final ink = selected ? _Bar.selectedInk : KitTokens.toolbarOnBar;
    Widget button = Material(
      color: selected
          ? KitTokens.toolbarOnBar
          : open
          ? _Bar.openFill
          : Colors.transparent,
      borderRadius: shape,
      child: InkWell(
        borderRadius: shape,
        onTap: onPressed,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.translate(
              offset: Offset(
                dropdown ? KitTokens.toolbarDropdownIconShift : 0,
                0,
              ),
              child: KitIcon(
                icon,
                size: KitTokens.toolbarIconSize,
                strokeWidth: KitTokens.toolbarIconStroke,
                color: ink,
                selected: selected,
              ),
            ),
            // in the last 8 of the button: the preview's `auto 8px` grid
            // stretches the icon's column to 32
            if (dropdown)
              Positioned(
                left:
                    KitTokens.toolbarDropdownWidth -
                    KitTokens.toolbarDropdownColumn / 2 -
                    KitDropdownMark.width / 2,
                top:
                    size / 2 -
                    KitTokens.toolbarDropdownMarkRise +
                    KitDropdownMark.arm * KitDropdownMark.half / 2 -
                    KitDropdownMark.height / 2,
                child: KitDropdownMark(color: ink),
              ),
            // `.b.rec::after`: its ring the bar's colour, outside it
            if (mark case final mark?)
              Positioned(
                top: KitTokens.recMarkInset,
                right: KitTokens.recMarkInset,
                child: SizedBox.square(
                  dimension: KitTokens.recMarkSize,
                  child: DecoratedBox(
                    key: const ValueKey('editor-record-mark'),
                    decoration: BoxDecoration(
                      color: mark,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: KitTokens.toolbarBg,
                        width: KitTokens.recMarkRing,
                        strokeAlign: BorderSide.strokeAlignOutside,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (ring) {
      button = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: shape,
          border: Border.all(color: _Bar.modeRing, width: _Bar.modeRingWidth),
        ),
        child: button,
      );
    }
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: tooltip,
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onPressed,
        child: SizedBox(
          width: width + KitTokens.toolbarGroupGap,
          height: KitTokens.toolbarHeight,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Tooltip(
                message: tooltip,
                child: Opacity(
                  opacity: (dimmed ?? !enabled) ? KitTokens.disabledOpacity : 1,
                  child: SizedBox(width: width, height: size, child: button),
                ),
              ),
              if (centreAnchor != null)
                Positioned(
                  left: side,
                  width: width,
                  top:
                      (KitTokens.toolbarHeight + size) / 2 +
                      KitTokens.toolWindowGapToolbar,
                  height: 0,
                  child: SizedBox(key: centreAnchor),
                ),
              if (anchor != null)
                Positioned(
                  left: side + size - (anchorRightAligned ?? size),
                  top: KitTokens.toolbarHeight + _Bar.windowGap,
                  width: 0,
                  height: 0,
                  child: SizedBox(key: anchor),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
