import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:saber/data/planner/planner_models.dart';

/// A drawing surface for planner handwriting: the reminder memo and the
/// calendar's month ink. Pen and finger both draw; with [erasing] a touch
/// takes away every stroke it meets.
///
/// Points are kept in 0..1 of the pad and widths as a fraction of its width,
/// so the same strokes fit the pad at any size and the home-screen widget.
/// The pad fills its parent, which must give it a bounded size.
class InkPad extends StatefulWidget {
  const new({
    super.key,
    required this.strokes,
    required this.onChanged,
    this.enabled = true,
    this.color = 0xFF202124,
    this.width = 0.006,
    this.erasing = false,
  });

  final List<InkStroke> strokes;

  /// The whole new list after a stroke was drawn or erased. A new stroke has
  /// no id and no time yet; the planner store stamps both when it writes.
  final ValueChanged<List<InkStroke>> onChanged;

  /// False shows the strokes and lets touches through to what lies below.
  final bool enabled;

  /// ARGB of new strokes.
  final int color;

  /// Width of new strokes, as a fraction of the pad's width.
  final double width;

  final bool erasing;

  @override
  State<InkPad> createState() => _InkPadState();
}

class _InkPadState extends State<InkPad> {
  /// How close, in logical pixels, the eraser must come to a stroke.
  static const _eraserReach = 12.0;

  int? _pointer;
  PointerDeviceKind? _kind;
  var _erasingNow = false;

  /// The stroke being drawn, in pixels of the pad.
  List<Offset>? _live;
  Offset? _lastErase;

  /// What was last sent through onChanged, until the parent passes a new
  /// list: two changes before the next build then build on each other.
  List<InkStroke>? _sent;

  List<InkStroke> get _strokes => _sent ?? widget.strokes;

  @override
  void didUpdateWidget(InkPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.strokes, widget.strokes)) _sent = null;
    if (oldWidget.enabled && !widget.enabled) {
      // A stroke in progress is dropped, and its pointer no longer holds the
      // pad: switched on again, the pad takes the next touch.
      _pointer = null;
      _kind = null;
      _lastErase = null;
      _live = null;
    }
  }

  void _send(List<InkStroke> strokes) {
    _sent = strokes;
    widget.onChanged(strokes);
  }

  void _down(PointerDownEvent event) {
    if (_pointer != null) {
      // A pen landing while a finger (or the palm) draws takes over, and
      // the finger's stroke is dropped. Anything else waits its turn.
      final penOverTouch =
          event.kind == PointerDeviceKind.stylus &&
          _kind != PointerDeviceKind.stylus;
      if (!penOverTouch) return;
    }
    _pointer = event.pointer;
    _kind = event.kind;
    _erasingNow = widget.erasing;
    _lastErase = null;
    if (_erasingNow) {
      setState(() => _live = null);
      _erase(event.localPosition);
    } else {
      setState(() => _live = [event.localPosition]);
    }
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if (_erasingNow) {
      _erase(event.localPosition);
      return;
    }
    final live = _live;
    if (live == null || (event.localPosition - live.last).distance < 1) return;
    setState(() => live.add(event.localPosition));
  }

  void _up(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final live = _live;
    _stop();
    final size = context.size;
    if (live == null || size == null || size.isEmpty) return;
    _send([
      ..._strokes,
      InkStroke(
        points: [
          for (final point in live) ...[
            _unit(point.dx, size.width),
            _unit(point.dy, size.height),
          ],
        ],
        color: widget.color,
        width: widget.width,
      ),
    ]);
  }

  void _cancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _stop();
  }

  void _stop() {
    _pointer = null;
    _kind = null;
    _lastErase = null;
    if (_live != null) setState(() => _live = null);
  }

  /// [value] in 0..1 of [extent], rounded to 4 places to keep files small.
  static double _unit(double value, double extent) =>
      ((value / extent).clamp(0.0, 1.0) * 10000).roundToDouble() / 10000;

  void _erase(Offset at) {
    final size = context.size;
    if (size == null || size.isEmpty) return;
    final from = _lastErase ?? at;
    _lastErase = at;
    final strokes = _strokes;
    final kept = [
      for (final stroke in strokes)
        if (!_touches(stroke, from, at, size)) stroke,
    ];
    if (kept.length != strokes.length) _send(kept);
  }

  /// Whether the eraser, moving from [from] to [to], comes within reach of
  /// [stroke]. The path is checked in steps no longer than the reach.
  static bool _touches(InkStroke stroke, Offset from, Offset to, Size size) {
    final reach = _eraserReach + stroke.width * size.width / 2;
    final points = _pixels(stroke, size);
    if (points.isEmpty) return false;
    final steps = math.max(1, ((to - from).distance / _eraserReach).ceil());
    for (var step = 0; step <= steps; step++) {
      final at = Offset.lerp(from, to, step / steps)!;
      if (points.length == 1 && (points.single - at).distance <= reach) {
        return true;
      }
      for (var i = 0; i + 1 < points.length; i++) {
        if (_distanceToSegment(at, points[i], points[i + 1]) <= reach) {
          return true;
        }
      }
    }
    return false;
  }

  static double _distanceToSegment(Offset point, Offset a, Offset b) {
    final ab = b - a;
    final length = ab.distanceSquared;
    if (length == 0) return (point - a).distance;
    final ap = point - a;
    final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / length).clamp(0.0, 1.0);
    return (point - (a + ab * t)).distance;
  }

  @override
  Widget build(BuildContext context) {
    final painted = RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _InkPainter(
            strokes: _strokes,
            live: _live,
            liveCount: _live?.length ?? 0,
            color: widget.color,
            width: widget.width,
          ),
        ),
      ),
    );
    if (!widget.enabled) return IgnorePointer(child: painted);
    return RawGestureDetector(
      // Wins every touch on the pad at once, so a stroke never scrolls or
      // swipes what holds the pad.
      gestures: {
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              EagerGestureRecognizer.new,
              (_) {},
            ),
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _cancel,
        child: painted,
      ),
    );
  }
}

List<Offset> _pixels(InkStroke stroke, Size size) => [
  for (var i = 0; i + 1 < stroke.points.length; i += 2)
    Offset(stroke.points[i] * size.width, stroke.points[i + 1] * size.height),
];

class _InkPainter extends CustomPainter {
  const new({
    required this.strokes,
    required this.live,
    required this.liveCount,
    required this.color,
    required this.width,
  });

  final List<InkStroke> strokes;
  final List<Offset>? live;

  /// The live list grows in place; its length tells a new point.
  final int liveCount;
  final int color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    for (final stroke in strokes) {
      _line(
        canvas,
        _pixels(stroke, size),
        Color(stroke.color),
        stroke.width * size.width,
      );
    }
    final live = this.live;
    if (live != null) _line(canvas, live, Color(color), width * size.width);
  }

  static void _line(
    Canvas canvas,
    List<Offset> points,
    Color color,
    double width,
  ) {
    if (points.isEmpty) return;
    final thickness = math.max(1.0, width);
    if (points.length == 1) {
      canvas.drawCircle(points.single, thickness / 2, Paint()..color = color);
      return;
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_InkPainter old) =>
      !identical(old.strokes, strokes) ||
      !identical(old.live, live) ||
      old.liveCount != liveCount ||
      old.color != color ||
      old.width != width;
}
