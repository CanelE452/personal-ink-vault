part of 'infinite_canvas.dart';

/// The infinite note's move tool on the toolbar (the editor has none).
const _moveTool = ToolbarTool(
  'move',
  '이동',
  KitIconName.move,
  AppActionIds.toolMove,
);

/// The infinite note's tools on the editor toolbar: the ones its engine has
/// (design 「다른 문서와 무한 노트」) in the editor's order, then 이동 (ledger
/// ruling, Task 18). Its highlighter is one of the floating bar's pens,
/// under the pen button.
final _infiniteTools = [
  toolbarToolOf('lasso'),
  toolbarToolOf('pen'),
  toolbarToolOf('eraser'),
  _moveTool,
];

/// Joins the infinite note's own tools ([_Tool]) to the editor's toolbar,
/// floating bar, pen panel and eraser and lasso windows (Task 18; progress
/// Task 12 → 18). Those take the engine's [Tool]s, so the pen and the
/// highlighter are [_InfinitePen]s that read and write the infinite note's
/// own width and colour, and the eraser is an [Eraser] the floating bar
/// knows by its type. [engine] tells the bars what the infinite note can do;
/// [toolState] follows the tool, the colour and the width ([sync]).
class _InkAdapter implements InkToolHost {
  new(this._canvas);

  final InfiniteCanvasState _canvas;

  late final pen = _InfinitePen(_canvas, highlighter: false);
  late final highlighter = _InfinitePen(_canvas, highlighter: true);
  final _eraser = Eraser();

  /// The infinite note's pen and flat highlighter; no pen box, straight line
  /// or stabiliser; the stroke eraser; its strokes are pens and highlighters.
  late final engine = InkEngineSupport(
    pens: {KitPenKind.fountain: pen, KitPenKind.highlighterChisel: highlighter},
    penSettings: false,
    eraserModes: const [EraserMode.stroke],
    eraserTargets: const [StrokeKind.pen, StrokeKind.highlighter],
    lassoTargets: [stows.selectInk, stows.selectHighlighter],
  );

  /// The tool in hand as the floating bar sees it.
  Tool get currentTool => switch (_canvas._tool) {
    _Tool.pen => pen,
    _Tool.highlighter => highlighter,
    _Tool.eraser => _eraser,
    _Tool.lasso || _Tool.pan => const _NoBarTool(),
  };

  @override
  late final toolState = InkToolState(currentTool);

  /// Tells [toolState] the tool in hand, with its colour and width: the
  /// canvas calls it when one of them changes.
  void sync() => toolState.update(tool: currentTool);

  /// A pen chosen on the floating bar or in the pen panel; none while a
  /// stroke goes on.
  @override
  void selectTool(Tool tool) {
    if (tool is! _InfinitePen || _canvas._interacting) return;
    _canvas._setTool(tool.highlighter ? _Tool.highlighter : _Tool.pen);
  }

  @override
  void setColor(Color color) => _canvas._setColor(color);

  @override
  void setSize(double size) {
    if (currentTool case final Pen pen) pen.setSize(size);
  }

  /// Nothing: the infinite note has no stabiliser (its engine has no pen
  /// settings), and its pens keep nothing in the editor's settings.
  @override
  void setStabiliser(double value) {}

  /// Nothing: the infinite note's pens have no opacity or line style yet
  /// (stage 2 Task 27), so its pen panel shows neither row.
  @override
  void setAlpha(int alpha) {}

  @override
  void setLineStyle(KitPenDash style) {}

  /// The toolbar button of the tool in hand (the pen button holds the
  /// highlighter too).
  ToolbarTool get toolbarTool => switch (_canvas._tool) {
    _Tool.pen || _Tool.highlighter => toolbarToolOf('pen'),
    _Tool.eraser => toolbarToolOf('eraser'),
    _Tool.lasso => toolbarToolOf('lasso'),
    _Tool.pan => _moveTool,
  };

  /// The infinite note's actions (its own registry, no parent): undo and
  /// redo, the tools, 「원점으로」 and 「저장」, and finger writing (the
  /// editor's setting; Ctrl+F, and the workspace row's ⋯ shows it). Nothing
  /// runs while a stroke goes on.
  List<AppAction> actions() {
    final canvas = _canvas;
    final tool = canvas._tool;
    void unlessBusy(VoidCallback then) {
      if (!canvas._interacting) then();
    }

    AppAction toolAction(
      String id,
      String label,
      KitIconName icon,
      _Tool value, {
      bool? checked,
    }) => AppAction(
      id: id,
      label: label,
      icon: icon,
      checked: checked ?? tool == value,
      run: (_) => unlessBusy(() => canvas._setTool(value)),
    );

    return [
      AppAction(
        id: AppActionIds.undo,
        label: '실행 취소',
        icon: KitIconName.undo,
        enabled: canvas._undo.isNotEmpty,
        run: (_) => canvas._undoOrRedo(redo: false),
      ),
      AppAction(
        id: AppActionIds.redo,
        label: '다시 실행',
        icon: KitIconName.redo,
        enabled: canvas._redo.isNotEmpty,
        run: (_) => canvas._undoOrRedo(redo: true),
      ),
      // back to the pen or the highlighter last in hand
      toolAction(
        AppActionIds.toolPen,
        '펜',
        KitIconName.pen,
        canvas._lastInk,
        checked: tool == _Tool.pen,
      ),
      toolAction(
        AppActionIds.toolHighlighter,
        '형광펜',
        KitIconName.marker,
        _Tool.highlighter,
      ),
      toolAction(
        AppActionIds.toolEraser,
        '지우개',
        KitIconName.eraser,
        _Tool.eraser,
      ),
      toolAction(
        AppActionIds.toolLasso,
        '올가미',
        KitIconName.lassoFree,
        _Tool.lasso,
      ),
      toolAction(AppActionIds.toolMove, '이동', KitIconName.move, _Tool.pan),
      AppAction(
        id: AppActionIds.canvasOrigin,
        label: '원점으로',
        // a crosshair: the home is the tab row's (final review design call 5)
        icon: KitIconName.origin,
        run: (_) => unlessBusy(canvas._goToOrigin),
      ),
      // while it saves, a clock and 「저장 중」 (on)
      AppAction(
        id: AppActionIds.canvasSave,
        label: canvas._saving ? '저장 중' : '저장',
        icon: canvas._saving
            ? KitIconName.clock
            : canvas._dirty
            ? KitIconName.saved
            : KitIconName.checkCircle,
        checked: canvas._saving,
        enabled: !canvas._saving,
        run: (_) => unlessBusy(() => unawaited(canvas._saveFromUi())),
      ),
      AppAction(
        id: AppActionIds.finger,
        label: '손가락 필기',
        icon: KitIconName.tap,
        checked: stows.editorFingerDrawing.value,
        run: (_) => unlessBusy(
          () => stows.editorFingerDrawing.value =
              !stows.editorFingerDrawing.value,
        ),
      ),
      // the toolbar's mode button and the editor's keys; 확대 잠금 is the
      // editor's setting (the zoom badge and the gestures read it)
      AppAction(
        id: AppActionIds.gestureMode,
        label: '제스처 모드',
        icon: KitIconName.palm,
        run: (_) => stows.editorGestureMode.value =
            !stows.editorGestureMode.value,
      ),
      AppAction(
        id: AppActionIds.floatingBar,
        label: '떠 있는 막대',
        icon: KitIconName.brush,
        run: (_) =>
            canvas._floatingBarOpen.value = !canvas._floatingBarOpen.value,
      ),
      AppAction(
        id: AppActionIds.zoomLock,
        label: '확대 잠금',
        icon: KitIconName.zoom,
        run: (_) => stows.lastZoomLock.value = !stows.lastZoomLock.value,
      ),
      // writing again, with the eraser and its bar
      AppAction(
        id: AppActionIds.eraserBar,
        label: '지우개',
        icon: KitIconName.eraser,
        run: (context) {
          stows.editorGestureMode.value = false;
          canvas._actions.run(AppActionIds.toolEraser, context);
          canvas._floatingBarOpen.value = true;
        },
      ),
    ];
  }
}

/// The infinite note's pen or highlighter as the floating bar and the pen
/// panel see it: the pen panel's fine-nib pen or flat highlighter, with the
/// infinite note's widths (the pen 1 to 8; the highlighter five times the
/// pen's, 5 to 40, as the old width menu) and its one colour. It keeps
/// nothing in the editor's pen settings.
class _InfinitePen extends Pen {
  new(this._canvas, {required this.highlighter})
    : super(
        name: highlighter ? '형광펜' : '펜',
        sizeMin: _scaleOf(highlighter) * InfiniteCanvasState._minWidth,
        sizeMax: _scaleOf(highlighter) * InfiniteCanvasState._maxWidth,
        sizeStep: _scaleOf(highlighter) * .5,
        icon: highlighter ? Highlighter.highlighterIcon : Pen.fountainPenIcon,
        options: StrokeOptions(),
        pressureEnabled: !highlighter,
        color: Color(_canvas._color.value),
        toolId: highlighter ? ToolId.highlighter : ToolId.fountainPen,
      );

  final InfiniteCanvasState _canvas;
  final bool highlighter;

  static double _scaleOf(bool highlighter) =>
      highlighter ? InfiniteCanvasState._highlighterScale : 1;

  double get _scale => _scaleOf(highlighter);

  @override
  StrokeOptions get options =>
      StrokeOptions(size: _canvas._width.value * _scale);

  @override
  set options(StrokeOptions value) => _canvas._selectWidth(value.size / _scale);

  @override
  Color get color => Color(_canvas._color.value);

  @override
  set color(Color value) => _canvas._setColor(value);

  @override
  List<double> get sizePresets => [
    for (final width in InfiniteCanvasState._quickWidths) width * _scale,
  ];

  @override
  void setSize(double size) => _canvas._selectWidth(size / _scale);

  @override
  void setColor(Color color) => _canvas._setColor(color);
}

/// The lasso and the move tool, which have no floating bar.
class _NoBarTool extends Tool {
  const new();

  @override
  ToolId get toolId => ToolId.select;
}
