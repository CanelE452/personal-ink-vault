import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart' show StrokeOptions;
import 'package:saber/components/ink_ui/ink_engine_support.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_box.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_color_row.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_column.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_kinds.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_panel_common.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:sbn/tool_id.dart';
import 'package:stow_plain/stow_plain.dart';

/// Which pens a [KitPenPanel] offers: the pens, or the highlighters.
enum KitPenPanelKind { pens, highlighters }

/// The Samsung style pen panel (preview `snPanel`, 7th draft): the head (pen
/// box, star, collapse, close), the pens with the chosen one raised and its
/// sample stroke on its tip, then the size, the straight-line switch and the
/// colours, and last the pens' stroke stabiliser or, on the highlighter
/// panel, the horizontal/vertical switch under the straight line. Stage 1
/// offers only the pens the engine has and hides the opacity row, the line
/// types and the highlighter's text-height row.
///
/// The tool in hand is always read with [currentTool]. The panel draws itself
/// again after each change it asks for, so the host never has to rebuild it.
/// Dragging the size or the stabiliser only redraws the slider (and the
/// sample); the value is kept once, when the drag ends. When the screen is
/// too short (split screen) the rows under the pens scroll.
///
/// A host with its own ink engine ([engine], the infinite note) gets its own
/// pens, and without the engine's pen settings no pen box, star, straight
/// line switches or stabiliser.
class KitPenPanel extends StatefulWidget {
  const new({
    super.key,
    required this.kind,
    required this.currentTool,
    required this.setTool,
    required this.setColor,
    required this.onClose,
    required this.collapsed,
    this.actions,
    this.onSizeLevel,
    this.engine = InkEngineSupport.editor,
  });

  final KitPenPanelKind kind;
  final ValueGetter<Tool> currentTool;
  final ValueChanged<Tool> setTool;
  final ValueChanged<Color> setColor;
  final VoidCallback onClose;

  /// Whether only the head and the pens show. The host keeps it, so a panel
  /// opened again stays as it was left (the floating bar hands it
  /// `stows.penPanelCollapsed`).
  final ValueNotifier<bool> collapsed;

  /// The editor's actions: the eyedropper shows when it publishes one.
  final AppActionRegistry? actions;

  /// Told the size number the panel shows whenever it changes, while the
  /// slider is dragged too (the floating bar's width icon follows it).
  final ValueChanged<int>? onSizeLevel;

  /// What the document's ink engine has.
  final InkEngineSupport engine;

  @override
  State<KitPenPanel> createState() => _KitPenPanelState();
}

class _KitPenPanelState extends State<KitPenPanel> {
  final _boxAnchor = GlobalKey();
  late final ValueNotifier<int> _level;

  /// The stabilisation shown, in percent.
  late final ValueNotifier<int> _stab;

  /// The pen [_level] and [_stab] were read from.
  Pen? _levelPen;

  /// The setting that pen keeps its options in, listened to so a
  /// stabilisation set elsewhere shows here.
  PlainStow<StrokeOptions>? _options;

  Pen? get _pen => switch (widget.currentTool()) {
    final Pen pen => pen,
    _ => null,
  };

  bool get _highlighters => widget.kind == KitPenPanelKind.highlighters;

  List<KitPenKind> get _kinds => [
    for (final k in widget.engine.penKinds)
      if (k.isHighlighter == _highlighters) k,
  ];

  bool get _penSettings => widget.engine.penSettings;

  /// The panel's straight-line setting: one for all pens, one for the
  /// highlighter.
  PlainStow<bool> get _straight =>
      _highlighters ? stows.highlighterStraightLine : stows.autoStraightenLines;

  static int _levelOf(Pen pen) =>
      sizeToLevel(pen.options.size, min: pen.sizeMin, max: pen.sizeMax);

  static int _stabOf(Pen pen) => (pen.options.streamline * 100).round();

  /// Whether [pen] shows the stabiliser: the pens it steadies (as
  /// [Pen.onDragStart] decides), on the pen panel only, as in the preview.
  bool _stabilised(Pen pen) =>
      _penSettings && !_highlighters && pen is! Highlighter && pen is! ShapePen;

  /// The setting [pen] keeps its options in ([Pen] writes them there), for
  /// the pens the stabiliser shows for.
  static PlainStow<StrokeOptions>? _optionsOf(Pen? pen) =>
      switch (pen?.toolId) {
        ToolId.fountainPen => stows.lastFountainPenOptions,
        ToolId.ballpointPen => stows.lastBallpointPenOptions,
        ToolId.pencil => stows.lastPencilOptions,
        _ => null,
      };

  void _listenToOptions(Pen? pen) {
    final next = _optionsOf(pen);
    if (identical(next, _options)) return;
    _options?.removeListener(_optionsChanged);
    _options = next?..addListener(_optionsChanged);
  }

  void _optionsChanged() =>
      _stab.value = (_options!.value.streamline * 100).round();

  @override
  void initState() {
    super.initState();
    _levelPen = _pen;
    _level = ValueNotifier(_levelPen == null ? 1 : _levelOf(_levelPen!))
      ..addListener(() => widget.onSizeLevel?.call(_level.value));
    _stab = ValueNotifier(_levelPen == null ? 0 : _stabOf(_levelPen!));
    _listenToOptions(_levelPen);
  }

  @override
  void dispose() {
    _options?.removeListener(_optionsChanged);
    _level.dispose();
    _stab.dispose();
    super.dispose();
  }

  /// Reads the tool in hand again after a change; another pen brings its own
  /// size and stabilisation, and its own setting to listen to.
  void _refresh() {
    if (!mounted) return;
    final pen = _pen;
    if (!identical(pen, _levelPen)) {
      _levelPen = pen;
      _listenToOptions(pen);
      if (pen != null) {
        _level.value = _levelOf(pen);
        _stab.value = _stabOf(pen);
      }
    }
    setState(() {});
  }

  void _choose(KitPenKind kind) {
    if (penKindOf(widget.currentTool()) == kind) return;
    widget.setTool(widget.engine.toolFor(kind));
    _refresh();
  }

  void _setColor(Color colour) {
    widget.setColor(colour);
    _refresh();
  }

  void _keepSize(int level) {
    final pen = _pen;
    // The same number keeps the size as it is: a size kept before may sit
    // between two numbers, and a tap on the thumb should not move it.
    if (pen == null || level == _levelOf(pen)) return;
    pen.setSize(levelToSize(level, min: pen.sizeMin, max: pen.sizeMax));
    _refresh();
  }

  void _keepStab(int percent) {
    final pen = _pen;
    // As with the size, the same number leaves the value alone: one kept
    // before may lie between the tens.
    if (pen == null || percent == _stabOf(pen)) return;
    pen.setStreamline(percent / 100);
    _refresh();
  }

  Future<void> _openPenBox() async {
    await showKitPenBox(
      context,
      anchor: _boxAnchor,
      setTool: widget.setTool,
      setColor: widget.setColor,
      currentTool: widget.currentTool,
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final pen = _pen;
    final invert = inkInverted(context);
    return PenPanelSurface(
      key: const ValueKey('kit-pen-panel'),
      child: ValueListenableBuilder(
        valueListenable: widget.collapsed,
        builder: (context, collapsed, _) => Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _head(pen, collapsed),
                _penRow(pen, invert, collapsed),
                if (!collapsed && pen != null)
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _rows(pen, invert),
                      ),
                    ),
                  ),
              ],
            ),
            // The pen box opens here: on the pen row, edge to edge with the
            // panel, clear of the close circle.
            Positioned(
              left: -KitTokens.penPanelBorderWidth,
              right: -KitTokens.penPanelBorderWidth,
              top: KitTokens.penPanelHeadHit,
              height: 0,
              child: SizedBox(key: _boxAnchor),
            ),
          ],
        ),
      ),
    );
  }

  /// The head with the panel's top padding in it: each button is pressed in
  /// 44 x 44 from the panel's top edge, its icon where the preview draws it
  /// (22 icons at 20, the close circle at 19, 14 in from the sides).
  Widget _head(Pen? pen, bool collapsed) => SizedBox(
    height: KitTokens.penPanelHeadHit,
    child: Row(
      children: [
        if (_penSettings) ...[
          PenPanelHeadButton(
            key: const ValueKey('pen-panel-pen-box-open'),
            left: KitTokens.penPanelPadH,
            label: '펜 상자 열기',
            onTap: _openPenBox,
            child: penPanelHeadIcon(KitIconName.penbox),
          ),
          ValueListenableBuilder(
            valueListenable: stows.penBox,
            builder: (context, _, _) => _star(pen),
          ),
        ],
        const Spacer(),
        PenPanelHeadEnd(
          collapsed: collapsed,
          onCollapse: () => widget.collapsed.value = !collapsed,
          onClose: widget.onClose,
        ),
      ],
    ),
  );

  /// The star keeps the pen in hand in the pen box, or takes it out again. A
  /// full box takes no new pen.
  Widget _star(Pen? pen) {
    final entry = pen == null ? null : PenBoxEntry.of(pen);
    final entries = PenBox.entries;
    final kept = entry != null && entries.contains(entry);
    final canPress =
        entry != null && (kept || entries.length < PenBox.maxEntries);
    return PenPanelHeadButton(
      key: const ValueKey('toolbar-pen-box'),
      // 14 after the pen box icon, which is 22 into its own button
      left:
          KitTokens.penPanelPadH +
          KitTokens.penPanelIconSize +
          KitTokens.penPanelHeadGap -
          KitTokens.penPanelHeadHit,
      label: kept ? '펜 상자에서 빼기' : '펜 상자에 넣기',
      selected: kept,
      onTap: canPress
          ? () => kept ? PenBox.remove(entry) : PenBox.add(entry)
          : null,
      child: Opacity(
        opacity: canPress ? 1 : KitTokens.disabledOpacity,
        child: penPanelHeadIcon(KitIconName.star, selected: kept),
      ),
    );
  }

  Widget _penRow(Pen? pen, bool invert, bool collapsed) {
    final chosen = pen == null ? null : penKindOf(pen);
    final kinds = _kinds;
    final gap = _highlighters
        ? KitTokens.penColumnGapHighlighter
        : KitTokens.penColumnGap;
    // When collapsed the panel ends under the pens, without the line.
    final line = collapsed ? 0.0 : KitTokens.penRowLine;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: KitTokens.penPanelPadH - KitTokens.penRowInset,
      ),
      child: SizedBox(
        height: KitTokens.penRowHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: line == 0
                  ? BorderSide.none
                  : BorderSide(color: KitTokens.penPanelBorder, width: line),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.only(bottom: line),
            child: ClipRect(
              child: ValueListenableBuilder(
                valueListenable: _straight,
                builder: (context, straight, _) => Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, k) in kinds.indexed) ...[
                      if (i > 0) SizedBox(width: gap),
                      PenPanelColumn(
                        key: ValueKey('pen-panel-pen-${k.previewId}'),
                        kind: k,
                        chosen: k == chosen,
                        ink: visibleInk(
                          k == chosen
                              ? pen!.color
                              : (widget.engine.toolFor(k) as Pen).color,
                          invert,
                        ),
                        ruler: _penSettings && straight,
                        level: _level,
                        onTap: () => _choose(k),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _rows(Pen pen, bool invert) {
    final kind = penKindOf(pen);
    final ink = visibleInk(pen.color, invert);
    final stabiliser = _stabilised(pen);
    return [
      const SizedBox(height: KitTokens.penPanelRowsTop),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: KitTokens.penPanelPadH),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: const ValueKey('pen-panel-size'),
              height: KitTokens.penPanelRowHeight,
              child: Center(
                child: ValueListenableBuilder(
                  valueListenable: _level,
                  builder: (context, level, _) => KitSlider(
                    value: level,
                    onChanged: (v) => _level.value = v,
                    onChangeEnd: _keepSize,
                    // the preview's `size` slider names (`SLD.size`)
                    label: '굵기',
                    decreaseLabel: '가늘게',
                    increaseLabel: '굵게',
                    markColor: ink,
                    markDiameter: kind == null
                        ? null
                        : (v) => _markDiameter(kind, v),
                  ),
                ),
              ),
            ),
            if (_penSettings)
              ValueListenableBuilder(
                valueListenable: _straight,
                builder: (context, on, _) => KitToggleRow(
                  key: const ValueKey('toolbar-auto-straighten'),
                  label: '직선 자동 보정',
                  value: on,
                  onChanged: (v) => _straight.value = v,
                ),
              ),
            if (_penSettings && _highlighters) _axisLock(),
            const SizedBox(height: KitTokens.penPanelColorsTop),
            KitPenColorRow(
              key: const ValueKey('pen-panel-colors'),
              selected: pen.color,
              onSelected: _setColor,
              onEyedropper: colourRowEyedropper(
                widget.actions,
                context,
                close: () => widget.onClose(),
              ),
            ),
          ],
        ),
      ),
      // The page dots are pressed in a 44 high band, so the colour row ends
      // 19.5 under the dots: in the bottom padding, or 3.5 into the
      // stabiliser, which lies 16 under the dots.
      if (stabiliser) ...[
        Transform.translate(
          offset: const Offset(0, -_dotsBandIntoStabiliser),
          child: _stabiliser(),
        ),
        const SizedBox(
          height: KitTokens.penPanelPadBottom - _dotsBandIntoStabiliser,
        ),
      ] else
        const SizedBox(height: KitTokens.penPanelPadBottom - _dotsBandBelow),
    ];
  }

  static const _dotsBandBelow =
      (KitTokens.pageDotHitZone - KitTokens.pageDot) / 2;
  static const _dotsBandIntoStabiliser =
      _dotsBandBelow - KitTokens.penPanelStabTop;

  /// 「수평/수직 그리기」 (preview `axisRow`): the highlighter's lock to the
  /// nearer of horizontal and vertical works only with its straight line, so
  /// while that is off the row is dimmed and its note says to turn it on. It
  /// listens to both settings. Both notes are one line (user change 1), so
  /// the panel keeps its height when the straight line is turned on.
  Widget _axisLock() => ListenableBuilder(
    listenable: Listenable.merge([
      stows.highlighterStraightLine,
      stows.highlighterAxisLock,
    ]),
    builder: (context, _) {
      final straight = stows.highlighterStraightLine.value;
      return KitToggleRow(
        key: const ValueKey('tool-panel-axis-lock'),
        label: '수평/수직 그리기',
        description: straight
            ? '선을 수평·수직 중 가까운 쪽으로 맞춥니다.'
            : '먼저 위의 ‘직선 자동 보정’을 켜세요.',
        value: stows.highlighterAxisLock.value,
        onChanged: straight ? (v) => stows.highlighterAxisLock.value = v : null,
      );
    },
  );

  /// 「스트로크 안정화」 (preview `stabRow`, `.snp .stab`): a line as wide as
  /// the pen row's, the title with the value at its end, a note, then a
  /// 0-100 slider in tens with the number alone on its thumb. Dragging
  /// redraws only the slider and the value; the pen keeps the value once,
  /// when it ends.
  Widget _stabiliser() => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: KitTokens.penPanelPadH - KitTokens.penRowInset,
    ),
    child: DecoratedBox(
      key: const ValueKey('tool-panel-stabiliser'),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(
            color: KitTokens.penPanelBorder,
            width: KitTokens.penRowLine,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KitTokens.penRowInset,
          KitTokens.penRowLine + KitTokens.penPanelStabPadTop,
          KitTokens.penRowInset,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(
                top: KitTokens.penPanelStabTitlePadTop,
              ),
              // the value on the title's line, its rounded line at the same
              // foot as the title's (`.stv`, not read out: the slider says it)
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const KitLines(
                    '스트로크 안정화',
                    style: TextStyle(
                      fontSize: KitTokens.toggleLabelSize,
                      height: KitTokens.toggleLabelLineHeight,
                      color: KitTokens.menuInk,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: ExcludeSemantics(
                      child: ValueListenableBuilder(
                        valueListenable: _stab,
                        builder: (context, percent, _) => KitText(
                          '$percent%',
                          key: const ValueKey('tool-panel-stabiliser-value'),
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            fontSize: KitTokens.toggleLabelSize,
                            height: KitTokens.toggleLabelLineHeight,
                            color: KitTokens.menuSub,
                            decoration: TextDecoration.none,
                            fontWeight: FontWeight.w400,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: KitTokens.toggleSubTop),
              child: KitLines(
                '높을수록 선이 부드럽고 약간 늦게 따라갑니다.',
                style: TextStyle(
                  fontSize: KitTokens.menuSubSize,
                  height: KitTokens.toggleSubLineHeight,
                  color: KitTokens.menuSub,
                  decoration: TextDecoration.none,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            SizedBox(
              height: KitTokens.penPanelRowHeight,
              child: Center(
                child: ValueListenableBuilder(
                  valueListenable: _stab,
                  builder: (context, percent, _) => KitSlider(
                    value: percent,
                    onChanged: (v) => _stab.value = v,
                    onChangeEnd: _keepStab,
                    min: 0,
                    max: 100,
                    step: 10,
                    snap: 10,
                    // the preview's `stab` slider (`SLD.stab`): its names,
                    // and the unit said but drawn at the title instead
                    unit: '%',
                    label: '스트로크 안정화',
                    decreaseLabel: '안정화 줄이기',
                    increaseLabel: '안정화 늘리기',
                    markColor: KitTokens.sliderMarkInk,
                    markDiameter: (_) => KitTokens.sliderMarkSize,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// The dot in the held size pill: the pen's own width at [level].
  static double _markDiameter(KitPenKind kind, int level) =>
      ((KitTokens.penMarkWidths[kind.previewId] ?? KitTokens.penMarkMin) *
              kitPenK(kind, level) *
              KitTokens.penMarkScale)
          .clamp(KitTokens.penMarkMin, KitTokens.penMarkMax);
}
