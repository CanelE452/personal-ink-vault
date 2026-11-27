import 'dart:async';

import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/ink_engine_support.dart';
import 'package:saber/components/ink_ui/tool_panels/kit_eraser_panel.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';

/// A line between two groups of a floating bar pill (`.fbar .vsep`): the
/// pill's divider with 3 on each side along the pill.
Widget floatingBarDivider(Axis axis) => Padding(
  padding: axis == Axis.vertical
      ? const EdgeInsets.symmetric(vertical: KitTokens.pillDividerMargin)
      : const EdgeInsets.symmetric(horizontal: KitTokens.pillDividerMargin),
  child: const KitPillDivider(),
);

/// The tool pill of a bar narrower than its tools (a phone, values §13-2):
/// faded to clear over [KitTokens.floatingBarEdgeFade] at each end where
/// tools run past it, pill and all; nothing when they all show.
class FloatingBarEdgeFade extends StatelessWidget {
  const new({
    super.key,
    required this.axis,
    required this.start,
    required this.end,
    required this.child,
  });

  final Axis axis;

  /// Tools run past the start (left or top), or the end.
  final bool start;
  final bool end;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!start && !end) return child;
    final across = axis == Axis.horizontal;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final length = across ? bounds.width : bounds.height;
        final f = length <= 0 ? 0.0 : KitTokens.floatingBarEdgeFade / length;
        final first = start ? Colors.transparent : Colors.black;
        final last = end ? Colors.transparent : Colors.black;
        return LinearGradient(
          begin: across ? Alignment.centerLeft : Alignment.topCenter,
          end: across ? Alignment.centerRight : Alignment.bottomCenter,
          colors: [first, Colors.black, Colors.black, last],
          stops: [0, f, 1 - f, 1],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}

/// A bar button with the place where the windows it opens start: at the
/// button's start, [KitTokens.floatingBarPanelGap] under the pill, or
/// [KitTokens.floatingBarPanelGapUpright] beside it when the bar is upright.
/// [centred] (the eraser's windows, across the top): as wide as the button,
/// [KitTokens.toolWindowGapBar] under it, for a window centred under it.
class FloatingBarAnchor extends StatelessWidget {
  const new({
    super.key,
    required this.anchor,
    required this.axis,
    required this.child,
    this.centred = false,
  });

  /// The key [openFromFloatingBar] opens at.
  final GlobalKey anchor;
  final Axis axis;
  final Widget child;
  final bool centred;

  @override
  Widget build(BuildContext context) {
    final upright = axis == Axis.vertical;
    // past the pill's padding beside the button (`3px 6px`, upright
    // `6px 3px`) and its border
    final edge =
        KitTokens.pillButton +
        (upright
            ? KitTokens.pillVerticalPaddingAlong
            : KitTokens.pillPaddingAcross) +
        KitTokens.pillBorderWidth;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (centred && !upright)
          Positioned(
            left: 0,
            right: 0,
            top: KitTokens.pillButton + KitTokens.toolWindowGapBar,
            height: 0,
            child: SizedBox(key: anchor),
          )
        else
          Positioned(
            left: upright ? edge + KitTokens.floatingBarPanelGapUpright : 0,
            top: upright ? 0 : edge + KitTokens.floatingBarPanelGap,
            width: 0,
            height: 0,
            child: SizedBox(key: anchor),
          ),
      ],
    );
  }
}

/// The page area the floating bar lies over: the windows the bar opens stay
/// inside it (a phone's page is narrower than the pen panel's place).
class FloatingBarArea extends StatelessWidget {
  const new({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Opens a window at a [FloatingBarAnchor]: it grows down from under the
/// bar, or to the right beside the upright bar, and stays in the
/// [FloatingBarArea] around [anchor]. A [toolWindow] (the eraser's, 10th
/// draft) has the menu window's look and, across the top, a nub pointing at
/// the button it hangs from.
Future<void> openFromFloatingBar(
  BuildContext context, {
  required GlobalKey anchor,
  required Axis axis,
  required WidgetBuilder builder,
  bool toolWindow = false,
}) {
  RenderBox? area;
  anchor.currentContext?.visitAncestorElements((element) {
    if (element.widget is! FloatingBarArea) return true;
    area = element.findRenderObject() as RenderBox?;
    return false;
  });
  return showKitPopover<void>(
    context: context,
    anchor: anchor,
    grow: axis == Axis.vertical ? AxisDirection.right : AxisDirection.down,
    builder: builder,
    within: area,
    shadows: toolWindow ? KitTokens.menuShadow : null,
    border: !toolWindow,
    nub: toolWindow && axis == Axis.horizontal,
  );
}

/// The tool pill while the eraser is in hand (preview 10th draft 1-d,
/// `fbHtml`): the kind chip, 「고급 설정」, a line, then the three sizes.
/// The chip opens 「지우개 종류」 and the toggles button 「고급 설정」, each
/// hanging under its button; 「쪽 비우기」 there asks first and then runs the
/// document's `clearPage`. The sizes are shortcuts to the slider's 10, 40 and
/// 80; the one equal to the size in hand is ringed. Circle select does not
/// use the size, so they are dimmed then. It follows the eraser's settings
/// wherever they change. Its windows offer only the kinds and targets
/// [engine] has.
class FloatingBarEraserPill extends StatefulWidget {
  const new({
    super.key,
    required this.axis,
    required this.actions,
    this.raised = false,
    this.scrollController,
    this.engine = InkEngineSupport.editor,
  });

  final Axis axis;

  /// What the document's ink engine has.
  final InkEngineSupport engine;

  /// The document's actions: 「쪽 비우기」 runs `clearPage` from here.
  final AppActionRegistry actions;

  /// Whether the bar is picked up ([KitPill.raised]).
  final bool raised;

  /// [KitPill.scrollController].
  final ScrollController? scrollController;

  @override
  State<FloatingBarEraserPill> createState() => _FloatingBarEraserPillState();
}

class _FloatingBarEraserPillState extends State<FloatingBarEraserPill> {
  final _kindAnchor = GlobalKey();
  final _advancedAnchor = GlobalKey();

  /// The window open now ('kind', 'advanced'), drawn on its button.
  String? _open;

  Future<void> _openWindow(
    String which,
    GlobalKey anchor,
    WidgetBuilder builder,
  ) async {
    setState(() => _open = which);
    await openFromFloatingBar(
      context,
      anchor: anchor,
      axis: widget.axis,
      builder: builder,
      toolWindow: true,
    );
    if (mounted) setState(() => _open = null);
  }

  /// Closes 「고급 설정」, asks, then clears the page.
  Future<void> _clearPage(BuildContext window) async {
    Navigator.of(window).pop();
    if (!await confirmClearPage(context) || !mounted) return;
    widget.actions.run(AppActionIds.clearPage, context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([stows.eraserMode, stows.eraserSize]),
    builder: (context, _) {
      final axis = widget.axis;
      final mode = widget.engine.eraserModeOf(stows.eraserMode.value);
      final level = eraserLevel();
      final noSize = mode == EraserMode.lasso;
      return KitPill(
        key: const ValueKey('floating-bar-tool-pill'),
        direction: axis,
        raised: widget.raised,
        scrollController: widget.scrollController,
        children: [
          FloatingBarAnchor(
            anchor: _kindAnchor,
            axis: axis,
            centred: true,
            child: _KindChip(
              key: const ValueKey('floating-bar-eraser-kind'),
              mode: mode,
              open: _open == 'kind',
              onPressed: () => unawaited(
                _openWindow(
                  'kind',
                  _kindAnchor,
                  (context) => KitEraserTypePanel(engine: widget.engine),
                ),
              ),
            ),
          ),
          FloatingBarAnchor(
            anchor: _advancedAnchor,
            axis: axis,
            centred: true,
            child: KitSquareButton(
              key: const ValueKey('floating-bar-eraser-advanced'),
              icon: KitIconName.toggles,
              tooltip: KitIconName.toggles.label,
              size: KitTokens.pillButton,
              radius: KitTokens.pillButtonRadius,
              iconSize: KitTokens.toolbarIconSize,
              iconStroke: KitTokens.toolbarIconStroke,
              iconColor: KitTokens.pillInk,
              selectedFill: KitTokens.eraserAdvancedOpenFill,
              selectedIconColor: KitTokens.pillInk,
              selected: _open == 'advanced',
              onPressed: () {
                widget.engine.keepTargetsOn();
                unawaited(
                  _openWindow(
                    'advanced',
                    _advancedAnchor,
                    (window) => KitEraserAdvancedPanel(
                      onClearPage: widget.actions.has(AppActionIds.clearPage)
                          ? () => unawaited(_clearPage(window))
                          : null,
                      engine: widget.engine,
                    ),
                  ),
                );
              },
            ),
          ),
          floatingBarDivider(axis),
          for (final (i, preset) in KitTokens.eraserSizePresets.indexed)
            _SizePreset(
              key: ValueKey('floating-bar-eraser-size-$preset'),
              label: '크기 ${_sizeNames[i]}',
              diameter: KitTokens.eraserSizeCircles[i],
              chosen: level == preset,
              onPressed: noSize ? null : () => keepEraserLevel(preset),
            ),
        ],
      );
    },
  );
}

/// The three sizes' names (`SIZES`).
const _sizeNames = ['작게', '중간', '크게'];

/// The eraser's kind chip (`.fbar .e10chip`): the kind's icon, its short
/// name and a caret, white with a thin line inside, a darker one while its
/// window is open.
class _KindChip extends StatelessWidget {
  const new({
    super.key,
    required this.mode,
    required this.open,
    required this.onPressed,
  });

  final EraserMode mode;
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final kind = eraserKindOf(mode);
    final label = '지우개 종류: ${kind.name}';
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(KitTokens.eraserChipRadius),
      side: open
          ? const BorderSide(
              color: KitTokens.eraserChipOpenEdge,
              width: KitTokens.eraserChipOpenEdgeWidth,
            )
          : const BorderSide(color: KitTokens.eraserChipEdge),
    );
    return Semantics(
      button: true,
      expanded: open,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: KitTokens.eraserChipMinWidth,
          ),
          child: SizedBox(
            height: KitTokens.eraserChipHeight,
            child: Material(
              color: KitTokens.eraserChipBg,
              shape: shape,
              child: InkWell(
                customBorder: shape,
                onTap: onPressed,
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: KitTokens.eraserChipPadStart,
                    right: KitTokens.eraserChipPadEnd,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: KitTokens.eraserChipGap,
                    children: [
                      KitIcon(
                        kind.icon,
                        size: KitTokens.eraserChipIconSize,
                        strokeWidth: KitTokens.eraserChipIconStroke,
                        color: KitTokens.pillInk,
                      ),
                      KitText(
                        kind.short,
                        style: const TextStyle(
                          fontSize: KitTokens.eraserChipTextSize,
                          height: KitTokens.lineHeightOne,
                          fontWeight: FontWeight.w600,
                          color: KitTokens.pillInk,
                          letterSpacing: 0,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(
                          left: KitTokens.eraserChipCaretGap,
                        ),
                        child: Opacity(
                          opacity: KitTokens.eraserChipCaretOpacity,
                          child: CustomPaint(
                            size: Size(
                              KitTokens.eraserChipCaretWidth,
                              KitTokens.eraserChipCaretHeight,
                            ),
                            painter: _Caret(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The chip's caret: a triangle pointing down (`::after`, CSS borders 4 4 5).
class _Caret extends CustomPainter {
  const new();

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close(),
    Paint()..color = KitTokens.pillInk,
  );

  @override
  bool shouldRepaint(_Caret old) => false;
}

/// One of the three sizes (`.fbar .pb.e10sz`): a checkered circle with a
/// grey line inside, ringed in the accent when it is the size in hand; with
/// [onPressed] null the whole button is dimmed.
class _SizePreset extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.diameter,
    required this.chosen,
    required this.onPressed,
  });

  final String label;
  final double diameter;
  final bool chosen;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    const out = KitTokens.eraserSizeRingGap + KitTokens.eraserSizeRingWidth;
    return FloatingBarDrawnButton(
      label: label,
      onPressed: onPressed,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox.square(
            key: const ValueKey('floating-bar-eraser-size-circle'),
            dimension: diameter,
            child: const CustomPaint(painter: _CheckedCircle()),
          ),
          if (chosen)
            const Positioned(
              left: -out,
              top: -out,
              right: -out,
              bottom: -out,
              child: DecoratedBox(
                key: ValueKey('floating-bar-eraser-size-ring'),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.fromBorderSide(
                    BorderSide(
                      color: KitTokens.accent,
                      width: KitTokens.eraserSizeRingWidth,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A size circle: a checker of [KitTokens.eraserSizeCheckerSquare] squares
/// from its top left (`repeating-conic-gradient(#fff 0 25%, #ececef 0 50%)
/// 0 0/6px 6px`) under a grey line inside its edge.
class _CheckedCircle extends CustomPainter {
  const new();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas
      ..save()
      ..clipPath(Path()..addOval(bounds))
      ..drawRect(bounds, Paint()..color = KitTokens.eraserChipBg);
    const square = KitTokens.eraserSizeCheckerSquare;
    final grey = Paint()..color = KitTokens.eraserSizeChecker;
    for (var y = 0; y * square < size.height; y++) {
      for (var x = 0; x * square < size.width; x++) {
        if ((x + y).isEven) {
          canvas.drawRect(
            Rect.fromLTWH(x * square, y * square, square, square),
            grey,
          );
        }
      }
    }
    canvas.restore();
    const line = KitTokens.eraserSizeEdgeWidth;
    canvas.drawOval(
      bounds.deflate(line / 2),
      Paint()
        ..color = KitTokens.eraserSizeEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = line,
    );
  }

  @override
  bool shouldRepaint(_CheckedCircle old) => false;
}

/// A bar button that shows its own mark instead of one of the set's icons
/// (the eraser's size ring, the colour wheel, the width in hand): the pill
/// button's 32 square and ink ripple, [child] in its middle, named [label];
/// with [onPressed] null the whole button is dimmed.
class FloatingBarDrawnButton extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.onPressed,
    required this.child,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(KitTokens.pillButtonRadius);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: Opacity(
          opacity: onPressed == null ? KitTokens.disabledOpacity : 1,
          child: SizedBox.square(
            dimension: KitTokens.pillButton,
            child: Material(
              color: Colors.transparent,
              borderRadius: shape,
              child: InkWell(
                borderRadius: shape,
                onTap: onPressed,
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
