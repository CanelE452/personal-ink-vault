import 'package:flutter/material.dart';
import 'package:path_drawing/path_drawing.dart';
import 'package:perfect_freehand/perfect_freehand.dart' show StrokeOptions;
import 'package:saber/components/ink_ui/pen_panel/kit_pen_box.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_color_row.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_column.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_panel_common.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/ink/ink_engine.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/app_settings.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:stow_plain/stow_plain.dart';

/// Which pens a [KitPenPanel] offers: the pens, or the highlighters.
enum KitPenPanelKind { pens, highlighters }

/// The Samsung style pen panel (preview `snPanel`, 7th draft): the head (pen
/// box, star, collapse, close), the pens with the chosen one raised and its
/// sample stroke on its tip, then the size, the straight-line switch and the
/// colours, and last the pens' stroke stabiliser or, on the highlighter
/// panel, the horizontal/vertical switch under the straight line. The
/// highlighters and the pencil have an opacity row under the size, the fine
/// pen its four line styles; the highlighter's text-height row stays hidden.
///
/// The tool in hand is always read from [host]'s tool state. The panel draws
/// itself again after each change it asks of [host], so the host never has
/// to rebuild it.
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
    required this.host,
    required this.onClose,
    required this.collapsed,
    this.actions,
    this.onSizeLevel,
    this.engine = InkEngineSupport.editor,
  });

  final KitPenPanelKind kind;

  /// The document: the tool in hand, and where a pen, colour, size or
  /// stabilisation chosen here goes.
  final InkToolHost host;
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

  /// The opacity shown, in percent of the pen's own ([defaultAlphaOf]).
  late final ValueNotifier<int> _opacity;

  /// The pen [_level] and [_stab] were read from.
  Pen? _levelPen;

  /// The setting that pen keeps its options in, listened to so a
  /// stabilisation set elsewhere shows here.
  PlainStow<StrokeOptions?>? _options;

  Pen? get _pen => switch (widget.host.toolState.tool) {
    final Pen pen => pen,
    _ => null,
  };

  bool get _highlighters => widget.kind == KitPenPanelKind.highlighters;

  List<KitPenKind> get _kinds => [
    for (final k in widget.engine.penKinds)
      if (k.isHighlighter == _highlighters) k,
  ];

  bool get _penSettings => widget.engine.penSettings;

  /// The straight line and the 수평/수직 of the pen in hand (each pen has
  /// its own).
  late final PenSettingInHand _straight;
  late final PenSettingInHand _axis;

  static int _levelOf(Pen pen) =>
      sizeToLevel(pen.options.size, min: pen.sizeMin, max: pen.sizeMax);

  static int _stabOf(Pen pen) => (pen.options.streamline * 100).round();

  /// Whether [pen] shows the stabiliser: the pens it steadies (as
  /// [Pen.onDragStart] decides), on the pen panel only, as in the preview.
  bool _stabilised(Pen pen) =>
      _penSettings && !_highlighters && pen is! Highlighter && pen is! ShapePen;

  /// Follows the setting [pen] keeps its options in ([Pen.optionsStow]), for
  /// the pens the stabiliser shows for.
  void _listenToOptions(Pen? pen) {
    final next = pen != null && _stabilised(pen) ? pen.optionsStow : null;
    if (identical(next, _options)) return;
    _options?.removeListener(_optionsChanged);
    _options = next?..addListener(_optionsChanged);
  }

  void _optionsChanged() {
    if (_options!.value case final options?) {
      _stab.value = (options.streamline * 100).round();
    }
  }

  @override
  void initState() {
    super.initState();
    _levelPen = _pen;
    _level = ValueNotifier(_levelPen == null ? 1 : _levelOf(_levelPen!))
      ..addListener(() => widget.onSizeLevel?.call(_level.value));
    _stab = ValueNotifier(_levelPen == null ? 0 : _stabOf(_levelPen!));
    _opacity = ValueNotifier(_opacityNow);
    _listenToOptions(_levelPen);
    // made now, while the host's tool state is there: the host may be gone
    // before this panel is
    _straight = PenSettingInHand.straightLine(widget.host.toolState);
    _axis = PenSettingInHand.axisLock(widget.host.toolState);
  }

  /// The opacity of the pen in hand in percent of its own: the highlighter's
  /// 100 of 255 is 100, so the default sits on the slider's end.
  int get _opacityNow {
    final state = widget.host.toolState;
    return (state.alpha * 100 / defaultAlphaOf(state.tool.toolId))
        .round()
        .clamp(KitTokens.opacityMin, KitTokens.opacityMax);
  }

  @override
  void dispose() {
    _options?.removeListener(_optionsChanged);
    _level.dispose();
    _stab.dispose();
    _opacity.dispose();
    _straight.dispose();
    _axis.dispose();
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
        _opacity.value = _opacityNow;
      }
    }
    setState(() {});
  }

  void _choose(KitPenKind kind) {
    if (penKindOf(widget.host.toolState.tool) == kind) return;
    widget.host.selectTool(widget.engine.toolFor(kind, widget.host.toolState));
    _refresh();
  }

  void _setColor(Color colour) {
    widget.host.setColor(colour);
    _refresh();
  }

  void _keepSize(int level) {
    final pen = _pen;
    // The same number keeps the size as it is: a size kept before may sit
    // between two numbers, and a tap on the thumb should not move it.
    if (pen == null || level == _levelOf(pen)) return;
    widget.host.setSize(levelToSize(level, min: pen.sizeMin, max: pen.sizeMax));
    _refresh();
  }

  void _keepStab(int percent) {
    final pen = _pen;
    // As with the size, the same number leaves the value alone: one kept
    // before may lie between the tens.
    if (pen == null || percent == _stabOf(pen)) return;
    widget.host.setStabiliser(percent / 100);
    _refresh();
  }

  void _keepOpacity(int percent) {
    final pen = _pen;
    if (pen == null || percent == _opacityNow) return;
    widget.host.setAlpha((defaultAlphaOf(pen.toolId) * percent / 100).round());
    _refresh();
  }

  void _setLine(KitPenDash style) {
    if (style == widget.host.toolState.lineStyle) return;
    widget.host.setLineStyle(style);
    _refresh();
  }

  Future<void> _openPenBox() async {
    await showKitPenBox(
      context,
      anchor: _boxAnchor,
      setTool: widget.host.selectTool,
      setColor: widget.host.setColor,
      currentTool: () => widget.host.toolState.tool,
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
              child: ListenableBuilder(
                // each pen's ruler shows its own straight line
                listenable: Listenable.merge([
                  stows.straightLineByPen,
                  stows.highlighterStraightLine,
                  _opacity,
                ]),
                builder: (context, _) => Row(
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
                              : (widget.engine.toolFor(
                                  k,
                                  widget.host.toolState,
                                ) as Pen).color,
                          invert,
                        ),
                        ruler: _penSettings && straightLineOf(k),
                        level: _level,
                        onTap: () => _choose(k),
                        alpha: k == chosen && pen!.opacityStow != null
                            ? _opacity.value / 100
                            : 1,
                        dash: k == chosen
                            ? widget.host.toolState.lineStyle
                            : KitPenDash.solid,
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
                // the dots carry the opacity, so they follow its slider too
                child: ListenableBuilder(
                  listenable: Listenable.merge([_level, _opacity]),
                  builder: (context, _) => KitSlider(
                    value: _level.value,
                    onChanged: (v) => _level.value = v,
                    onChangeEnd: _keepSize,
                    // the preview's `size` slider names (`SLD.size`)
                    label: '굵기',
                    decreaseLabel: '가늘게',
                    increaseLabel: '굵게',
                    markColor: pen.opacityStow == null
                        ? ink
                        : ink.withValues(alpha: _opacity.value / 100),
                    markDiameter: kind == null
                        ? null
                        : (v) => _markDiameter(kind, v),
                  ),
                ),
              ),
            ),
            if (pen.opacityStow != null) _opacityRow(ink),
            if (pen.lineStyleStow != null) _lineStyles(),
            // an ink pen's own straight line and 수평/수직 (the controller's
            // ruling: the same row for every ink pen); the shape pen has
            // neither
            if (_penSettings && kind != null)
              ValueListenableBuilder(
                valueListenable: _straight,
                builder: (context, on, _) => KitToggleRow(
                  key: const ValueKey('toolbar-auto-straighten'),
                  label: '직선 자동 보정',
                  value: on,
                  onChanged: (v) => _straight.value = v,
                ),
              ),
            if (_penSettings && kind != null) _axisLock(),
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

  /// 「수평/수직 그리기」 (preview `axisRow`): an ink pen's lock to the nearer
  /// of horizontal and vertical works only with its straight line, so
  /// while that is off the row is dimmed and its note says to turn it on
  /// (the settings table's rule, given this panel's pen in hand). It
  /// listens to both settings of the pen in hand. Both notes are one line
  /// (user change 1), so the panel keeps its height when the straight line
  /// is turned on.
  Widget _axisLock() => ListenableBuilder(
    listenable: Listenable.merge([_straight, _axis]),
    builder: (context, _) {
      final blocked = settingsRegistry.unusableReason(
        axisLockInHandKey,
        values: {straightLineInHandKey: _straight.value},
      );
      return KitToggleRow(
        key: const ValueKey('tool-panel-axis-lock'),
        label: '수평/수직 그리기',
        description: blocked ?? '선을 수평·수직 중 가까운 쪽으로 맞춥니다.',
        value: _axis.value,
        onChanged: blocked == null ? (v) => _axis.value = v : null,
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

  /// The dot in the held size pill: the pen's own width at [level] (preview
  /// `dotW`), the fine pen's after its line style.
  double _markDiameter(KitPenKind kind, int level) {
    final line = widget.host.toolState.lineStyle;
    if (kind == KitPenKind.calligraphy) {
      return KitTokens.penMarkCalliBase +
          KitTokens.penMarkCalliPerLevel * level;
    }
    if (kind == KitPenKind.finePen && line == KitPenDash.dot) {
      return [
        KitTokens.penMarkMin,
        KitTokens.penMarkDotBase + KitTokens.penMarkDotPerLevel * level,
        KitTokens.penMarkDotSlope * level - KitTokens.penMarkDotOffset,
      ].reduce((a, b) => a > b ? a : b);
    }
    var width =
        (KitTokens.penMarkWidths[kind.previewId] ?? KitTokens.penMarkMin) *
        kitPenK(kind, level) *
        KitTokens.penMarkScale;
    if (kind == KitPenKind.finePen && line == KitPenDash.thin) {
      width *= KitTokens.penMarkThinScale;
    }
    return width.clamp(KitTokens.penMarkMin, KitTokens.penMarkMax);
  }

  /// 「투명도」 (preview `slRow('alpha')`): the opacity in percent of the
  /// pen's own, on the checkerboard ramp to [ink]. The pen keeps it once,
  /// when a drag ends.
  Widget _opacityRow(Color ink) => SizedBox(
    key: const ValueKey('pen-panel-opacity'),
    height: KitTokens.penPanelRowHeight,
    child: Center(
      child: ValueListenableBuilder(
        valueListenable: _opacity,
        builder: (context, percent, _) => KitSlider(
          value: percent,
          onChanged: (v) => _opacity.value = v,
          onChangeEnd: _keepOpacity,
          min: KitTokens.opacityMin,
          max: KitTokens.opacityMax,
          step: KitTokens.opacityStep,
          // the preview's `alpha` slider names (`SLD.alpha`)
          label: '투명도',
          decreaseLabel: '흐리게',
          increaseLabel: '진하게',
          opacityInk: ink,
        ),
      ),
    ),
  );

  /// The fine pen's four lines (preview `.pills`): 실선, 가는 선, 파선, 점선.
  Widget _lineStyles() {
    final chosen = widget.host.toolState.lineStyle;
    const lines = [
      (KitPenDash.solid, '실선'),
      (KitPenDash.thin, '가는 선'),
      (KitPenDash.dash, '파선'),
      (KitPenDash.dot, '점선'),
    ];
    return Padding(
      key: const ValueKey('pen-panel-line-style'),
      padding: const EdgeInsets.symmetric(vertical: KitTokens.penLinePadV),
      child: Row(
        children: [
          for (final (i, (style, name)) in lines.indexed) ...[
            if (i > 0) const SizedBox(width: KitTokens.penLineGap),
            Expanded(
              child: Semantics(
                key: ValueKey('pen-panel-line-${style.name}'),
                button: true,
                selected: style == chosen,
                label: name,
                onTap: () => _setLine(style),
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setLine(style),
                  child: SizedBox(
                    height: KitTokens.penLinePillHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: style == chosen
                            ? KitTokens.penLinePillOnBg
                            : KitTokens.penLinePillBg,
                        borderRadius: BorderRadius.circular(
                          KitTokens.penLinePillRadius,
                        ),
                      ),
                      child: Center(
                        child: CustomPaint(
                          size: const Size(
                            KitTokens.penLineDrawingWidth,
                            KitTokens.penLineDrawingHeight,
                          ),
                          painter: _LinePainter(style),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One line style's drawing in its pill (preview `SP_LINES`).
class _LinePainter extends CustomPainter {
  const new(this.style);

  final KitPenDash style;

  @override
  void paint(Canvas canvas, Size size) {
    final (d, width, dashes) = KitTokens.penLineDrawings[style.name]!;
    final path = parseSvgPathData(d);
    canvas.drawPath(
      dashes.isEmpty
          ? path
          : dashPath(path, dashArray: CircularIntervalList(dashes)),
      Paint()
        ..color = KitTokens.penLineInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.style != style;
}
