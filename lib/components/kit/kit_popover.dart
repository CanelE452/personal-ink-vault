import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// Opens a small window next to [anchor] and grows it from there.
///
/// It is a route on the nearest [Navigator], so a popover opened from inside
/// another popover stacks on top of it, and a tap outside closes only the top
/// one. The routes underneath are not rebuilt, so the editor below is not
/// redrawn. The window follows the anchor: its place is read again on every
/// layout (rotation, resize, a moved bar). It is pushed inside the screen when
/// it would run past an edge, or inside [within] when given (the page area
/// under the floating bar).
///
/// With [nub] (a window growing down) the window's middle is put under the
/// anchor's middle and a nub on its top edge points there (the 10th draft's
/// eraser and lasso windows): give an anchor as wide as the button.
Future<T?> showKitPopover<T>({
  required BuildContext context,
  required GlobalKey anchor,
  required WidgetBuilder builder,
  AxisDirection grow = AxisDirection.down,
  BorderRadius? radius,
  List<BoxShadow>? shadows,
  bool border = true,
  RenderBox? within,
  bool nub = false,
}) {
  final navigator = Navigator.of(context);
  final anchorBox = anchor.currentContext?.findRenderObject() as RenderBox?;
  final navBox = navigator.context.findRenderObject() as RenderBox?;
  if (anchorBox == null || !anchorBox.attached || navBox == null) {
    return Future<T?>.value();
  }
  final topLeft = anchorBox.localToGlobal(Offset.zero, ancestor: navBox);
  return navigator.push(
    _KitPopoverRoute<T>(
      anchor: anchor,
      navigatorContext: navigator.context,
      firstRect: topLeft & anchorBox.size,
      grow: grow,
      builder: builder,
      radius: radius,
      shadows: shadows,
      border: border,
      within: within,
      nub: nub,
      open: KitMotion.of(context, KitMotionStep.normal),
      close: KitMotion.of(context, KitMotionStep.normal, closing: true),
    ),
  );
}

class _KitPopoverRoute<T> extends PopupRoute<T> {
  new({
    required this.anchor,
    required this.navigatorContext,
    required this.firstRect,
    required this.grow,
    required this.builder,
    required this.radius,
    required this.shadows,
    required this.border,
    required this.within,
    required this.nub,
    required this._open,
    required this._close,
  });

  final GlobalKey anchor;
  final BuildContext navigatorContext;
  final Rect firstRect;
  final AxisDirection grow;
  final WidgetBuilder builder;
  final BorderRadius? radius;
  final List<BoxShadow>? shadows;
  final bool border;
  final RenderBox? within;
  final bool nub;
  final Duration _open;
  final Duration _close;

  @override
  Duration get transitionDuration => _open;

  @override
  Duration get reverseTransitionDuration => _close;

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => KitIconName.close.label;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _AnchoredPage(
      anchor: anchor,
      navigatorContext: navigatorContext,
      firstRect: firstRect,
      grow: grow,
      builder: builder,
      radius: radius,
      shadows: shadows,
      border: border,
      within: within,
      nub: nub,
    );
  }

  Alignment get _origin => switch (grow) {
    AxisDirection.down => Alignment.topLeft,
    AxisDirection.up => Alignment.bottomLeft,
    AxisDirection.right => Alignment.topLeft,
    AxisDirection.left => Alignment.topRight,
  };

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: KitMotion.openCurve,
      reverseCurve: KitMotion.closeCurve,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(scale: curved, alignment: _origin, child: child),
    );
  }
}

/// Places the window next to the anchor and looks the anchor up again after
/// every build, which a screen size, inset or padding change triggers (the
/// page depends on the MediaQuery). The look-up runs after the frame because
/// the anchor's size may not be read while another subtree is laid out.
class _AnchoredPage extends StatefulWidget {
  const new({
    required this.anchor,
    required this.navigatorContext,
    required this.firstRect,
    required this.grow,
    required this.builder,
    required this.radius,
    required this.shadows,
    required this.border,
    required this.within,
    required this.nub,
  });

  final GlobalKey anchor;
  final BuildContext navigatorContext;
  final Rect firstRect;
  final AxisDirection grow;
  final WidgetBuilder builder;
  final BorderRadius? radius;
  final List<BoxShadow>? shadows;
  final bool border;
  final RenderBox? within;
  final bool nub;

  @override
  State<_AnchoredPage> createState() => _AnchoredPageState();
}

class _AnchoredPageState extends State<_AnchoredPage> {
  late Rect _rect = widget.firstRect;
  late Rect? _within = _area(widget.within);

  /// [box] on the navigator, null while it is not laid out.
  Rect? _area(RenderBox? box) {
    final nav = widget.navigatorContext.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize || nav == null) {
      return null;
    }
    return box.localToGlobal(Offset.zero, ancestor: nav) & box.size;
  }

  Rect? _read() =>
      _area(widget.anchor.currentContext?.findRenderObject() as RenderBox?);

  @override
  Widget build(BuildContext context) {
    MediaQuery.of(context); // rebuild when the screen metrics change
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final now = _read();
      final within = _area(widget.within) ?? _within;
      if (now != null && now != _rect || within != _within) {
        setState(() {
          _rect = now ?? _rect;
          _within = within;
        });
      }
    });
    final radius =
        widget.radius ?? BorderRadius.circular(KitTokens.penPanelRadius);
    final layout = _PopoverLayout(
      _rect,
      widget.grow,
      _within,
      centre: widget.nub,
    );
    final window = DecoratedBox(
      decoration: BoxDecoration(
        color: KitTokens.menuBg,
        border: widget.border
            ? Border.all(color: KitTokens.penPanelBorder)
            : null,
        borderRadius: radius,
        boxShadow: widget.shadows ?? KitTokens.panelShadow,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          // kept in a room smaller than it, it slides up and down inside,
          // its foot fading while there is more below
          child: widget.within == null
              ? widget.builder(context)
              : _FadingScroll(child: widget.builder(context)),
        ),
      ),
    );
    if (!widget.nub) {
      return CustomSingleChildLayout(delegate: layout, child: window);
    }
    return CustomMultiChildLayout(
      delegate: _NubLayout(layout),
      children: [
        LayoutId(id: _NubPart.window, child: window),
        LayoutId(id: _NubPart.nub, child: const _Nub()),
      ],
    );
  }
}

/// A window sliding inside its room (10th draft fix 1, `.e10in.more`): the
/// last [KitTokens.popoverScrollFade] fade to clear while there is more
/// below, nothing otherwise.
class _FadingScroll extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_FadingScroll> createState() => _FadingScrollState();
}

class _FadingScrollState extends State<_FadingScroll> {
  var _more = false;

  /// The view keeps its place when the fade comes and goes around it.
  final _view = GlobalKey();

  /// Follows the window's own view only: views inside the window (a pen
  /// panel's rows) tell of themselves too, from deeper down.
  bool _moved(int depth, ScrollMetrics m) {
    if (depth != 0 || m.axis != Axis.vertical) return false;
    final more = m.extentAfter > 1;
    if (more != _more) setState(() => _more = more);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final view = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _moved(n.depth, n.metrics),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) => _moved(n.depth, n.metrics),
        child: SingleChildScrollView(key: _view, child: widget.child),
      ),
    );
    if (!_more) return view;
    return ShaderMask(
      key: const ValueKey('kit-popover-fade'),
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final f = bounds.height <= 0
            ? 0.0
            : (1 - KitTokens.popoverScrollFade / bounds.height).clamp(0.0, 1.0);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Colors.black, Colors.black, Colors.transparent],
          stops: [0, f, 1],
        ).createShader(bounds);
      },
      child: view,
    );
  }
}

enum _NubPart { window, nub }

/// Lays the window out as [layout] does, then the nub over its top edge at
/// the anchor's middle, kept [KitTokens.toolWindowNubInset] from its sides.
class _NubLayout extends MultiChildLayoutDelegate {
  new(this.layout);

  final _PopoverLayout layout;

  @override
  void performLayout(Size size) {
    final window = layoutChild(
      _NubPart.window,
      layout.getConstraintsForChild(BoxConstraints.loose(size)),
    );
    final at = layout.getPositionForChild(size, window);
    positionChild(_NubPart.window, at);
    const side = KitTokens.toolWindowNub;
    layoutChild(_NubPart.nub, BoxConstraints.tight(const Size(side, side)));
    const inset = KitTokens.toolWindowNubInset;
    final x = window.width < 2 * inset
        ? window.width / 2
        : (layout.anchor.center.dx - at.dx).clamp(inset, window.width - inset);
    positionChild(
      _NubPart.nub,
      Offset(at.dx + x - side / 2, at.dy - KitTokens.toolWindowNubOver),
    );
  }

  @override
  bool shouldRelayout(_NubLayout old) => layout.shouldRelayout(old.layout);
}

/// The nub (`.e10o::before`): a square of the window's colour turned 45
/// degrees, its tip rounded, its two upper sides edged as the window is.
class _Nub extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => Transform.rotate(
    key: const ValueKey('kit-popover-nub'),
    angle: math.pi / 4,
    child: const DecoratedBox(
      decoration: BoxDecoration(
        color: KitTokens.menuBg,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(KitTokens.toolWindowNubCorner),
        ),
        boxShadow: [
          BoxShadow(color: KitTokens.toolWindowNubEdge, offset: Offset(-1, -1)),
        ],
      ),
    ),
  );
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  const new(this.anchor, this.grow, this.within, {this.centre = false});

  final Rect anchor;
  final AxisDirection grow;

  /// Growing down, the window's middle under the anchor's middle.
  final bool centre;

  /// The area to stay in, on the navigator; null, the whole of it.
  final Rect? within;

  /// The part of [within] from the anchor on (under the bar for a window
  /// growing down): the window does not cover what opened it, and keeps the
  /// anchor's gap from it even when it slides inside (the anchor is already
  /// that gap past the bar).
  Rect? get _room {
    final area = within;
    if (area == null) return null;
    final room = switch (grow) {
      AxisDirection.down => Rect.fromLTRB(
        area.left,
        math.max(area.top, anchor.top),
        area.right,
        area.bottom,
      ),
      AxisDirection.up => Rect.fromLTRB(
        area.left,
        area.top,
        area.right,
        math.min(area.bottom, anchor.bottom),
      ),
      AxisDirection.right => Rect.fromLTRB(
        math.max(area.left, anchor.left),
        area.top,
        area.right,
        area.bottom,
      ),
      AxisDirection.left => Rect.fromLTRB(
        area.left,
        area.top,
        math.min(area.right, anchor.right),
        area.bottom,
      ),
    };
    return room.width > 0 && room.height > 0 ? room : area;
  }

  bool get _vertical => grow == AxisDirection.down || grow == AxisDirection.up;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    if (_room case final room?) {
      // the far edge keeps the gap; a longer window slides inside
      const gap = KitTokens.popoverEdgeGap;
      return BoxConstraints(
        maxWidth: math.max(0, _vertical ? room.width : room.width - gap),
        maxHeight: math.max(0, _vertical ? room.height - gap : room.height),
      );
    }
    return BoxConstraints(
      maxWidth: (constraints.maxWidth - 2 * KitTokens.popoverEdgeGap).clamp(
        0,
        double.infinity,
      ),
      maxHeight: (constraints.maxHeight - 2 * KitTokens.popoverEdgeGap).clamp(
        0,
        double.infinity,
      ),
    );
  }

  /// Keeps [start]..[start]+[extent] inside 0..[room], with the edge gap when
  /// there is space for it, centered when the window is as big as the room.
  static double _fit(double start, double extent, double room) {
    if (extent + 2 * KitTokens.popoverEdgeGap >= room)
      return (room - extent) / 2;
    return start.clamp(
      KitTokens.popoverEdgeGap,
      room - extent - KitTokens.popoverEdgeGap,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final a = anchor;
    final (double x, double y) = switch (grow) {
      AxisDirection.down => (
        centre ? a.center.dx - child.width / 2 : a.left,
        a.bottom,
      ),
      AxisDirection.up => (a.left, a.top - child.height),
      AxisDirection.right => (a.right, a.top),
      AxisDirection.left => (a.left - child.width, a.top),
    };
    if (_room case final room?) {
      // along the way it grows it starts at the anchor (it fits the room by
      // its constraints); across, it is kept in the room as before
      return switch (grow) {
        AxisDirection.down => Offset(
          room.left + _fit(x - room.left, child.width, room.width),
          room.top,
        ),
        AxisDirection.up => Offset(
          room.left + _fit(x - room.left, child.width, room.width),
          room.bottom - child.height,
        ),
        AxisDirection.right => Offset(
          room.left,
          room.top + _fit(y - room.top, child.height, room.height),
        ),
        AxisDirection.left => Offset(
          room.right - child.width,
          room.top + _fit(y - room.top, child.height, room.height),
        ),
      };
    }
    return Offset(
      _fit(x, child.width, size.width),
      _fit(y, child.height, size.height),
    );
  }

  @override
  bool shouldRelayout(_PopoverLayout old) =>
      anchor != old.anchor ||
      grow != old.grow ||
      within != old.within ||
      centre != old.centre;
}
