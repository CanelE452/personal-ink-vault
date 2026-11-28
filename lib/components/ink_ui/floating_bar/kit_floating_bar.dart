import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform;
import 'package:flutter/gestures.dart'
    show GestureDisposition, LongPressGestureRecognizer, PointerMoveEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, SystemMouseCursors;
import 'package:saber/components/ink_ui/floating_bar/floating_bar_parts.dart';
import 'package:saber/components/ink_ui/hide_while_writing.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_color_row.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_panel_common.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_swatches.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/ink/ink_engine.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/pen.dart';

/// The floating bar (preview `#fbar`, 8th draft f): the undo pill and the
/// tool pill, across the top of the canvas area or upright at its left
/// (`stows.floatingBarPosition`). With a pen or the highlighter in hand the
/// tool pill holds the four pens, the width and the colours; with the eraser
/// its kind chip, 「고급 설정」 and three sizes (10th draft). The lasso, the
/// shape pen, the text box and the laser pointer have no bar (the lasso's
/// window hangs from its toolbar button).
///
/// The host lays it over the canvas area with `Positioned.fill`; taps beside
/// the pills reach the canvas. The bar follows the action registry, the
/// recent colours, the eraser settings and the host's tool state
/// ([InkToolHost.toolState]) itself and opens its windows itself, so the
/// host only hears of a new tool, colour or width. Held half
/// a second, anywhere on it, the bar is picked up (a light tap of the hand
/// and a deeper shadow); a move of more than 10 before then lets it go.
/// While it moves only the bar is drawn again, it stays on the page, and its
/// place is kept once, when it is let go a move of more than 10 away; the
/// bar then takes no taps for a moment.
///
/// Task 13B-2: it grows from the toolbar button that shows it ([growFrom])
/// and goes back into it; a page stroke under it fades it out of the way
/// ([strokeAt], [HideWhileWriting]); narrower than its tools (a phone), the
/// undo pill stays and only the tools slide, faded at the end they run past.
///
/// Task 18: the pens, eraser kinds and settings offered are the ones the
/// document's ink engine has ([engine]).
class KitFloatingBar extends StatefulWidget {
  const new({
    super.key,
    required this.host,
    required this.actions,
    required this.penPanelCollapsed,
    this.visible = true,
    this.growFrom,
    this.strokeAt,
    this.engine = InkEngineSupport.editor,
  });

  /// The document: the tool in hand, and where a tool, colour or width
  /// chosen here goes.
  final InkToolHost host;

  /// The document's actions: undo and redo come from here.
  final AppActionRegistry actions;

  /// Handed to the pen panels the bar opens (`stows.penPanelCollapsed`).
  final ValueNotifier<bool> penPanelCollapsed;

  /// Off, the bar goes away as it does for a tool without one (the editor
  /// toolbar's pen and eraser buttons show and hide it).
  final bool visible;

  /// Where across the screen the middle of the button that shows and hides
  /// the bar is: it grows from the top of the bar there (values §14-4).
  /// Null, from its own start.
  final ValueListenable<double?>? growFrom;

  /// The tip of the stroke on the page now, on the screen.
  final ValueListenable<Offset?>? strokeAt;

  /// What the document's ink engine has.
  final InkEngineSupport engine;

  @override
  State<KitFloatingBar> createState() => _KitFloatingBarState();
}

/// Whether the bar shows for [tool].
bool _shows(Tool tool) => isInkTool(tool) || tool is Eraser;

/// Whether [bar] is shown now.
bool _on(KitFloatingBar bar) => bar.visible && _shows(bar.host.toolState.tool);

KitIconName _penIcon(KitPenKind kind) => switch (kind) {
  KitPenKind.fountain || KitPenKind.calligraphy => KitIconName.fountain,
  KitPenKind.finePen => KitIconName.ball,
  KitPenKind.pencil => KitIconName.pencil,
  KitPenKind.brush => KitIconName.brush,
  KitPenKind.highlighterChisel ||
  KitPenKind.highlighterRound => KitIconName.marker,
};

/// The four dots' colours: the recent colours in their places, as far as
/// they read as colours, then the first of the default colours not among
/// them. The infinite note starts with the first.
List<Color> floatingBarDotColours() {
  const defaults = KitTokens.floatingBarDefaultColors;
  final colours = <Color>[];
  for (final s in stows.recentColorsPositioned.value) {
    if (colours.length == defaults.length) break;
    if (int.tryParse(s) case final v?) colours.add(Color(v));
  }
  for (final d in defaults) {
    if (colours.length == defaults.length) break;
    if (!colours.any((c) => c.withValues(alpha: 1) == d)) colours.add(d);
  }
  return colours;
}

/// The bar's hold: a long press (500 ms) that a move of more than
/// [KitTokens.floatingBarGrabSlop] across plus down lets go before it is
/// picked up, as the preview counts it (`|dx| + |dy|`, v8k line 2532).
/// Flutter's own counts straight, past the device's touch slop when a
/// [GestureDetector] hands it on (Android's is 8 dp by default), else 18;
/// this one is handed none, so only the count here decides. Picked up, it
/// moves freely.
class _GrabRecognizer extends LongPressGestureRecognizer {
  new({super.debugOwner});

  var _picked = false;

  @override
  void didExceedDeadline() {
    _picked = true;
    super.didExceedDeadline();
  }

  @override
  void handlePrimaryPointer(PointerEvent event) {
    if (!_picked && event is PointerMoveEvent) {
      final moved = event.position - initialPosition!.global;
      if (moved.dx.abs() + moved.dy.abs() > KitTokens.floatingBarGrabSlop) {
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(primaryPointer!);
        return;
      }
    }
    super.handlePrimaryPointer(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _picked = false;
    super.didStopTrackingLastPointer(pointer);
  }
}

class _KitFloatingBarState extends State<KitFloatingBar>
    with SingleTickerProviderStateMixin {
  late final _grow = AnimationController(vsync: this);
  // quick first and slow at the end both ways, as the preview's CSS
  late final _growCurve = CurvedAnimation(
    parent: _grow,
    curve: KitMotion.samsungDecel,
    reverseCurve: KitMotion.samsungDecel.flipped,
  );
  late final _growScale = Tween(
    begin: KitMotion.floatingBarGrowFrom,
    end: 1.0,
  ).animate(_growCurve);

  /// Where across the bar it grows from and goes into.
  var _growX = 0.0;

  /// The bar itself (the pills), to keep it on the page while it is held.
  final _barKey = GlobalKey();

  /// The tools sliding inside their pill on a narrow page, and which ends
  /// they run past.
  final _toolScroll = ScrollController();
  final _toolsPast = ValueNotifier((start: false, end: false));

  /// How far the held bar has moved, null while it is not held.
  final _held = ValueNotifier<Offset?>(null);

  /// Whether the bar is picked up: its pills cast the deeper shadow, and a
  /// mouse shows the grabbing hand.
  final _grabbed = ValueNotifier(false);

  /// Set for a moment after the bar is let go, while it takes no taps.
  final _swallowing = ValueNotifier(false);
  Timer? _swallowTimer;

  /// The size number the open pen panel shows (its slider moving too), null
  /// while it is closed: the width icon follows it.
  final _liveLevel = ValueNotifier<int?>(null);
  final _anchors = <String, GlobalKey>{};

  /// The tool the pills are drawn for: the one in hand while it has the
  /// bar, then the last such one while the bar goes.
  Tool? _shown;

  /// Whether the bar showed when the tool or [KitFloatingBar.visible] last
  /// changed: it grows in or goes when that changes.
  var _wasOn = false;

  GlobalKey _anchor(String id) => _anchors.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    // The first time it is drawn (the editor opened with a pen in hand) it
    // is there at once; it grows in only when a tool brings it back.
    if (_on(widget)) {
      _shown = widget.host.toolState.tool;
      _wasOn = true;
      _grow.value = 1;
    }
    _grow.addStatusListener(_gone);
    widget.host.toolState.addListener(_toolChanged);
  }

  /// Another tool, or the pen in hand changed (its colour, its width).
  void _toolChanged() => setState(_follow);

  /// Takes the pills away once the bar has gone.
  void _gone(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // the preview's one transition both ways (values §14-4), 0 with less
    // motion
    final grow = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : KitMotion.floatingBarGrow;
    _grow
      ..duration = grow
      ..reverseDuration = grow;
  }

  @override
  void didUpdateWidget(KitFloatingBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.host.toolState, widget.host.toolState)) {
      old.host.toolState.removeListener(_toolChanged);
      widget.host.toolState.addListener(_toolChanged);
    }
    _follow();
  }

  /// Takes the tool in hand for the pills, and grows the bar in or lets it
  /// go when it comes to show or stops showing.
  void _follow() {
    final shows = _on(widget);
    if (shows) _shown = widget.host.toolState.tool;
    if (shows && !_wasOn) {
      _growX = _growFromX();
      unawaited(_grow.forward());
    }
    if (!shows && _wasOn) {
      _putBack();
      _growX = _growFromX();
      unawaited(_grow.reverse());
    }
    _wasOn = shows;
  }

  @override
  void dispose() {
    widget.host.toolState.removeListener(_toolChanged);
    _swallowTimer?.cancel();
    _growCurve.dispose();
    _grow.dispose();
    _toolScroll.dispose();
    _toolsPast.dispose();
    _held.dispose();
    _grabbed.dispose();
    _swallowing.dispose();
    _liveLevel.dispose();
    super.dispose();
  }

  /// Picks the held bar up: a light tap of the hand (`vibrate(10)` in the
  /// preview) where there is a motor to give it, and the deeper shadow.
  void _pickUp() {
    _held.value = Offset.zero;
    _grabbed.value = true;
    // desktop engines answer no haptic call (flutter_windows.dll has none)
    if (defaultTargetPlatform
        case TargetPlatform.android || TargetPlatform.iOS) {
      unawaited(HapticFeedback.lightImpact());
    }
  }

  /// Puts the bar back where it was and down (the hold went, or the bar did).
  void _putBack() {
    _held.value = null;
    _grabbed.value = false;
  }

  /// Keeps the place the held bar was let go at: upright at the left when
  /// its left edge is near the canvas area's left, otherwise the top. The
  /// tap the release may make is swallowed (preview line 2532).
  ///
  /// Let go within [KitTokens.floatingBarGrabSlop] of where it was picked up
  /// (the pen resting on a button), it stays where it was.
  void _drop() {
    final held = _held.value;
    if (held == null) return;
    if (held.dx.abs() + held.dy.abs() > KitTokens.floatingBarGrabSlop) {
      final left = KitTokens.floatingBarInset + held.dx;
      stows.floatingBarPosition.value = left < KitTokens.floatingBarDockSnap
          ? 'left'
          : 'top';
    }
    _putBack();
    _swallowing.value = true;
    _swallowTimer?.cancel();
    _swallowTimer = Timer(
      KitMotion.barDropTapSwallow,
      () => _swallowing.value = false,
    );
  }

  /// The held bar moved [by], kept on the page area (values §9).
  Offset _onPage(Offset by) {
    final page = context.findRenderObject() as RenderBox?;
    final bar = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (page == null || bar == null || !page.hasSize || !bar.hasSize) {
      return by;
    }
    const inset = KitTokens.floatingBarInset;
    return Offset(
      by.dx.clamp(
        -inset,
        math.max(-inset, page.size.width - inset - bar.size.width),
      ),
      by.dy.clamp(
        -inset,
        math.max(-inset, page.size.height - inset - bar.size.height),
      ),
    );
  }

  /// [KitFloatingBar.growFrom] across the bar (the page area's render box
  /// is this widget's own, laid out in the frame before).
  double _growFromX() {
    final x = widget.growFrom?.value;
    final page = context.findRenderObject() as RenderBox?;
    if (x == null || page == null || !page.hasSize) return 0;
    final across = x - page.localToGlobal(Offset.zero).dx;
    final bar = across - KitTokens.floatingBarInset;
    // upright, the bar is a pill wide: a button, its padding and border
    const pill =
        KitTokens.pillButton +
        2 * (KitTokens.pillVerticalPaddingAlong + KitTokens.pillBorderWidth);
    final upright = stows.floatingBarPosition.value == 'left';
    return math.max(0, upright ? math.min(bar, pill) : bar);
  }

  /// Which ends of the tool pill the tools run past, from its scroll view.
  bool _toolsMoved(ScrollMetrics m) {
    final past = (
      start: m.pixels > m.minScrollExtent + 1,
      end: m.pixels < m.maxScrollExtent - 1,
    );
    if (_toolsPast.value != past) _toolsPast.value = past;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final shows = _on(widget);
    if (shown == null || !shows && _grow.isDismissed) {
      return const SizedBox.shrink();
    }
    return FloatingBarArea(
      child: RepaintBoundary(
        child: ValueListenableBuilder(
          valueListenable: stows.floatingBarPosition,
          builder: (context, place, _) {
            final axis = place == 'left' ? Axis.vertical : Axis.horizontal;
            return Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(KitTokens.floatingBarInset),
                // a stroke under it fades it out, and it takes no presses
                child: HideWhileWriting(
                  strokeAt: widget.strokeAt,
                  child: RawGestureDetector(
                    gestures: {
                      _GrabRecognizer:
                          GestureRecognizerFactoryWithHandlers<_GrabRecognizer>(
                            () => _GrabRecognizer(debugOwner: this),
                            (grab) => grab
                              ..onLongPressStart = ((_) => _pickUp())
                              ..onLongPressMoveUpdate = ((d) =>
                                  _held.value = _onPage(d.offsetFromOrigin))
                              ..onLongPressEnd = ((_) => _drop())
                              ..onLongPressCancel = _putBack,
                          ),
                    },
                    child: ValueListenableBuilder(
                      valueListenable: _held,
                      builder: (context, held, child) => Transform.translate(
                        offset: held ?? Offset.zero,
                        child: child,
                      ),
                      child: FadeTransition(
                        opacity: _growCurve,
                        // from .92 about the top of the bar at the button
                        // that shows it: scaled about its top left, then
                        // moved back by what that leaves at [_growX]
                        child: AnimatedBuilder(
                          animation: _growScale,
                          builder: (context, child) => Transform.translate(
                            offset: Offset(_growX * (1 - _growScale.value), 0),
                            child: child,
                          ),
                          child: ScaleTransition(
                            scale: _growScale,
                            alignment: Alignment.topLeft,
                            child: RepaintBoundary(
                              // A long press picks the bar up, so the
                              // buttons' names show on hover only: a
                              // tooltip's own long press would win over the
                              // bar's.
                              child: TooltipTheme(
                                data: TooltipTheme.of(context).copyWith(
                                  triggerMode: TooltipTriggerMode.manual,
                                ),
                                // while it goes, taps reach the canvas
                                child: IgnorePointer(
                                  ignoring: !shows,
                                  child: ListenableBuilder(
                                    listenable: Listenable.merge([
                                      _grabbed,
                                      _swallowing,
                                    ]),
                                    builder: (context, _) => MouseRegion(
                                      cursor: _grabbed.value
                                          ? SystemMouseCursors.grabbing
                                          : MouseCursor.defer,
                                      hitTestBehavior:
                                          HitTestBehavior.deferToChild,
                                      // held, its buttons are out of the
                                      // mouse's way (their own arrow would
                                      // show over the hand), and let go they
                                      // take no tap for a moment; the hold
                                      // itself goes on
                                      child: AbsorbPointer(
                                        absorbing:
                                            _grabbed.value || _swallowing.value,
                                        child: _pills(
                                          shown,
                                          axis,
                                          raised: _grabbed.value,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// The pills, [raised] while the bar is picked up. Narrower than the bar
  /// (a phone, values §13-2), the undo pill stays and the tools slide
  /// inside theirs, faded at the end they run past.
  Widget _pills(Tool tool, Axis axis, {required bool raised}) => KeyedSubtree(
    key: _barKey,
    child: Flex(
      key: const ValueKey('kit-floating-bar'),
      direction: axis,
      mainAxisSize: MainAxisSize.min,
      children: [
        ListenableBuilder(
          listenable: widget.actions,
          builder: (context, _) => _undoPill(axis, raised),
        ),
        Flexible(
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (n) => _toolsMoved(n.metrics),
            child: NotificationListener<ScrollUpdateNotification>(
              onNotification: (n) => _toolsMoved(n.metrics),
              child: ValueListenableBuilder(
                valueListenable: _toolsPast,
                builder: (context, past, child) => FloatingBarEdgeFade(
                  axis: axis,
                  start: past.start,
                  end: past.end,
                  child: child!,
                ),
                child: switch (tool) {
                  Eraser() => FloatingBarEraserPill(
                    axis: axis,
                    actions: widget.actions,
                    raised: raised,
                    scrollController: _toolScroll,
                    engine: widget.engine,
                  ),
                  final Pen pen => _penPill(pen, axis, raised),
                  _ => const SizedBox.shrink(),
                },
              ),
            ),
          ),
        ),
      ],
    ),
  );

  /// Undo and redo as the registry has them now: a missing one is left out,
  /// one that cannot run now is dimmed; without both there is no pill.
  Widget _undoPill(Axis axis, bool raised) {
    final buttons = [
      for (final id in const [AppActionIds.undo, AppActionIds.redo])
        if (widget.actions.lookup(id) case final action?)
          Builder(
            builder: (context) => KitPillButton(
              key: ValueKey('floating-bar-$id'),
              icon: action.icon,
              tooltip: action.label,
              onPressed: action.enabled
                  ? () => widget.actions.run(id, context)
                  : null,
            ),
          ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: axis == Axis.vertical
          ? const EdgeInsets.only(bottom: KitTokens.floatingBarGroupGap)
          : const EdgeInsets.only(right: KitTokens.floatingBarGroupGap),
      child: KitPill(
        key: const ValueKey('floating-bar-undo-pill'),
        direction: axis,
        raised: raised,
        children: buttons,
      ),
    );
  }

  /// The bar's pens ([InkEngineSupport.barPenKinds]; one button holds either
  /// highlighter), the width, the four colours and 「색 만들기」.
  Widget _penPill(Pen pen, Axis axis, bool raised) {
    final inHand = penKindOf(pen);
    bool chosen(KitPenKind kind) =>
        kind == inHand ||
        (kind.isHighlighter && (inHand?.isHighlighter ?? false));
    return KitPill(
      key: const ValueKey('floating-bar-tool-pill'),
      direction: axis,
      raised: raised,
      scrollController: _toolScroll,
      children: [
        for (final kind in widget.engine.barPenKinds)
          FloatingBarAnchor(
            anchor: _anchor(kind.previewId),
            axis: axis,
            child: KitPillButton(
              key: ValueKey('floating-bar-pen-${kind.previewId}'),
              icon: _penIcon(kind),
              tooltip: kind.label,
              selected: chosen(kind),
              onPressed: () {
                if (chosen(kind)) {
                  unawaited(_openPenPanel(kind, axis));
                } else {
                  widget.host.selectTool(
                    widget.engine.toolFor(kind, widget.host.toolState),
                  );
                }
              },
            ),
          ),
        floatingBarDivider(axis),
        FloatingBarAnchor(
          anchor: _anchor('width'),
          axis: axis,
          // the width in hand: the pen's, or the open pen panel's while its
          // slider moves (task-12-values.md §13)
          child: ValueListenableBuilder(
            valueListenable: _liveLevel,
            builder: (context, live, _) {
              final level =
                  live ??
                  sizeToLevel(
                    pen.options.size,
                    min: pen.sizeMin,
                    max: pen.sizeMax,
                  );
              return FloatingBarDrawnButton(
                key: const ValueKey('toolbar-quick-ink-widths'),
                // 「굵기 N」 with the pen panel's number, as the ring's 「크기 N」
                label: '${KitIconName.width.label} $level',
                onPressed: () => unawaited(_openWidths(pen, axis)),
                child: KitIcon(
                  KitIconName.width,
                  color: KitTokens.pillInk,
                  drawing: kitWidthDrawing(level),
                ),
              );
            },
          ),
        ),
        floatingBarDivider(axis),
        ListenableBuilder(
          listenable: stows.recentColorsPositioned,
          builder: (context, _) => _dots(context, pen, axis),
        ),
        FloatingBarAnchor(
          anchor: _anchor('custom'),
          axis: axis,
          child: FloatingBarDrawnButton(
            key: const ValueKey('floating-bar-custom-colour'),
            label: KitIconName.custom.label,
            onPressed: () => unawaited(_openColours(pen, axis)),
            // the pen panel's colour wheel with the dots' thin line inside;
            // its ring stays in the panel (task-12-values.md §13)
            child: SizedBox.square(
              dimension: KitTokens.colorDot,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: kitColourWheel,
                  border: Border.all(color: KitTokens.colorDotEdge),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The colour dots as the page shows them; a press keeps the colour itself.
  Widget _dots(BuildContext context, Pen pen, Axis axis) {
    final invert = inkInverted(context);
    final chosen = pen.color.withValues(alpha: 1);
    return Flex(
      direction: axis,
      mainAxisSize: MainAxisSize.min,
      spacing: KitTokens.pillGap,
      children: [
        for (final (i, c) in floatingBarDotColours().indexed)
          KitColorDot(
            key: ValueKey('floating-bar-colour-$i'),
            color: visibleInk(c, invert),
            label: '색 ${i + 1}',
            selected: c.withValues(alpha: 1) == chosen,
            onPressed: () => widget.host.setColor(c),
          ),
      ],
    );
  }

  /// Opens a window at the anchor [at], then draws the bar again (the
  /// window may have changed the pen's width or colour).
  Future<void> _open(String at, Axis axis, WidgetBuilder builder) async {
    await openFromFloatingBar(
      context,
      anchor: _anchor(at),
      axis: axis,
      builder: builder,
    );
    if (mounted) setState(() {});
  }

  Future<void> _openPenPanel(KitPenKind kind, Axis axis) async {
    await _open(
      kind.previewId,
      axis,
      (context) => KitPenPanel(
        kind: kind.isHighlighter
            ? KitPenPanelKind.highlighters
            : KitPenPanelKind.pens,
        host: widget.host,
        onClose: () => Navigator.of(context).pop(),
        collapsed: widget.penPanelCollapsed,
        actions: widget.actions,
        onSizeLevel: (level) {
          if (mounted) _liveLevel.value = level;
        },
        engine: widget.engine,
      ),
    );
    // closed: the width icon follows the pen's own width again
    if (mounted) _liveLevel.value = null;
  }

  /// The pen's three widths, each with the number the pen panel shows for
  /// it; the one within half a step of the pen's width is chosen.
  Future<void> _openWidths(Pen pen, Axis axis) =>
      _open('width', axis, (context) {
        final presets = pen.sizePresets ?? const <double>[];
        double? chosen;
        for (final p in presets) {
          if ((pen.options.size - p).abs() < 0.5) chosen = p;
        }
        return Padding(
          padding: const EdgeInsets.all(KitTokens.penPanelPadH),
          child: KitSegment<double?>(
            key: const ValueKey('floating-bar-widths'),
            options: [
              for (final p in presets)
                (p, '${sizeToLevel(p, min: pen.sizeMin, max: pen.sizeMax)}'),
            ],
            value: chosen,
            onChanged: (p) {
              widget.host.setSize(p!);
              Navigator.of(context).pop();
            },
          ),
        );
      });

  /// The pen panel's colour row alone, on the pen panel's box with its
  /// padding (the row ends in the page dots' band, as in the panel), with
  /// the eyedropper when the document has one.
  Future<void> _openColours(Pen pen, Axis axis) => _open(
    'custom',
    axis,
    (context) => PenPanelSurface(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KitTokens.penPanelPadH,
          KitTokens.penPanelRowsTop,
          KitTokens.penPanelPadH,
          KitTokens.penPanelPadBottom -
              (KitTokens.pageDotHitZone - KitTokens.pageDot) / 2,
        ),
        child: KitPenColorRow(
          key: const ValueKey('floating-bar-colours'),
          selected: pen.color,
          onSelected: (c) {
            widget.host.setColor(c);
            Navigator.of(context).pop();
          },
          onEyedropper: colourRowEyedropper(
            widget.actions,
            context,
            close: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    ),
  );
}
