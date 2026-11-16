import 'package:flutter/material.dart';
import 'package:sbn/tool_id.dart';

/// The pens drawn in the tool panels' pen trays and in the pen box. Our own
/// simple drawings: a tip at the top and a body running off the bottom.
enum PenShape {
  fountainPen,
  ballpointPen,
  pencil,
  shapePen,
  highlighterChisel,
  highlighterRound;

  static PenShape of(ToolId toolId) => switch (toolId) {
    .ballpointPen => ballpointPen,
    .pencil => pencil,
    .shapePen => shapePen,
    .highlighter => highlighterChisel,
    _ => fountainPen,
  };
}

class PenTrayItem {
  const new(this.shape, this.label, {this.enabled = true});

  final PenShape shape;
  final String label;

  /// False for a pen the engine cannot draw yet; it is shown faded and a tap
  /// says it is coming.
  final bool enabled;
}

/// A row of pens like a pen tray: the chosen pen is lifted and shows a
/// sample stroke in [color] above its tip.
class PenTray extends StatelessWidget {
  const new({
    super.key,
    required this.items,
    required this.selected,
    required this.color,
    required this.onSelected,
    this.comingSoonMessage = '',
  });

  final List<PenTrayItem> items;
  final PenShape selected;
  final Color color;
  final ValueChanged<PenShape> onSelected;
  final String comingSoonMessage;

  static const _slotWidth = 56.0;
  static const _height = 120.0;
  static const _sampleSpace = 30.0;
  static const _lift = 14.0;

  @override
  Widget build(BuildContext context) => ShaderMask(
    // The pens fade out at the bottom, as if they stood in a tray.
    blendMode: BlendMode.dstIn,
    shaderCallback: (rect) => const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.white, Colors.white, Colors.transparent],
      stops: [0, 0.72, 1],
    ).createShader(rect),
    child: SizedBox(
      height: _height,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [for (final item in items) _slot(item)],
      ),
    ),
  );

  Widget _slot(PenTrayItem item) {
    final chosen = item.shape == selected;
    final Widget slot = SizedBox(
      width: _slotWidth,
      height: _height,
      child: ClipRect(
        child: CustomPaint(
          painter: PenDrawingPainter(
            shape: item.shape,
            color: color,
            highlighted: chosen,
            top: _sampleSpace + (chosen ? 0 : _lift),
            sample: chosen,
          ),
        ),
      ),
    );
    if (!item.enabled) {
      return Tooltip(
        key: ValueKey('pen-type-${item.shape.name}'),
        triggerMode: TooltipTriggerMode.tap,
        message: comingSoonMessage,
        child: Opacity(opacity: 0.35, child: slot),
      );
    }
    return Semantics(
      button: true,
      selected: chosen,
      label: item.label,
      child: GestureDetector(
        key: ValueKey('pen-type-${item.shape.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelected(item.shape),
        child: slot,
      ),
    );
  }
}

/// Paints one pen with its tip at [top], centred across the canvas. With
/// [highlighted] the pen shows [color] on its body or tip; with [sample] a
/// short stroke in that colour is drawn above the tip.
class PenDrawingPainter extends CustomPainter {
  const new({
    required this.shape,
    required this.color,
    required this.top,
    this.highlighted = false,
    this.sample = false,
  });

  final PenShape shape;
  final Color color;
  final double top;
  final bool highlighted;
  final bool sample;

  static const _metal = Color(0xFFBDBDBD);
  static const _dark = Color(0xFF3C3C3C);
  static const _body = Color(0xFFCACACA);
  static const _light = Color(0xFFEDEDED);
  static const _edge = Color(0xFFD2D2D2);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final bottom = size.height + 4;
    final opaque = color.withValues(alpha: 1);
    final accent = highlighted ? opaque : _body;
    final fill = Paint()..isAntiAlias = true;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = _edge;

    void polygon(List<Offset> points, Color color, {bool outline = false}) {
      final path = Path()..addPolygon(points, true);
      canvas.drawPath(path, fill..color = color);
      if (outline) canvas.drawPath(path, edge);
    }

    void rect(double left, double t, double right, double b, Color color) =>
        canvas.drawRect(Rect.fromLTRB(left, t, right, b), fill..color = color);

    if (sample) _paintSample(canvas, cx);

    final t = top;
    switch (shape) {
      case PenShape.fountainPen:
        const w = 24.0;
        final nib = Path()
          ..moveTo(cx, t)
          ..quadraticBezierTo(cx + w * 0.42, t + 14, cx + w * 0.36, t + 30)
          ..lineTo(cx - w * 0.36, t + 30)
          ..quadraticBezierTo(cx - w * 0.42, t + 14, cx, t)
          ..close();
        canvas.drawPath(
          nib,
          fill
            ..shader = const LinearGradient(
              colors: [Color(0xFFF0F0F0), Color(0xFFA8A8A8)],
            ).createShader(Rect.fromLTRB(cx - w / 2, t, cx + w / 2, t + 30)),
        );
        fill.shader = null;
        canvas.drawLine(
          Offset(cx, t + 5),
          Offset(cx, t + 20),
          Paint()
            ..color = _dark
            ..strokeWidth = 1,
        );
        canvas.drawCircle(Offset(cx, t + 21), 1.8, fill..color = _dark);
        rect(cx - w * 0.38, t + 30, cx + w * 0.38, t + 44, const Color(0xFF8C8C8C));
        rect(cx - w * 0.42, t + 44, cx + w * 0.42, bottom, _body);
        rect(cx - w * 0.42, t + 48, cx + w * 0.42, t + 55, accent);
      case PenShape.ballpointPen:
        const w = 24.0;
        polygon([
          Offset(cx - 2, t + 3),
          Offset(cx + 2, t + 3),
          Offset(cx + w * 0.2, t + 14),
          Offset(cx - w * 0.2, t + 14),
        ], _metal);
        canvas.drawCircle(Offset(cx, t + 2), 1.6, fill..color = _dark);
        polygon([
          Offset(cx - w * 0.2, t + 14),
          Offset(cx + w * 0.2, t + 14),
          Offset(cx + w * 0.42, t + 34),
          Offset(cx - w * 0.42, t + 34),
        ], const Color(0xFFF7F7F7), outline: true);
        rect(cx - w * 0.42, t + 34, cx + w * 0.42, bottom, accent);
        rect(
          cx - w * 0.42,
          t + 62,
          cx + w * 0.42,
          t + 68,
          Colors.white.withValues(alpha: 0.7),
        );
      case PenShape.pencil:
        const w = 24.0;
        polygon([
          Offset(cx, t),
          Offset(cx + w * 0.14, t + 12),
          Offset(cx - w * 0.14, t + 12),
        ], _dark);
        polygon([
          Offset(cx - w * 0.14, t + 12),
          Offset(cx + w * 0.14, t + 12),
          Offset(cx + w * 0.42, t + 36),
          Offset(cx - w * 0.42, t + 36),
        ], const Color(0xFFEED3A8));
        rect(cx - w * 0.42, t + 36, cx + w * 0.42, bottom, const Color(0xFFD9D9D9));
        rect(cx - w * 0.42, t + 36, cx + w * 0.42, t + 41, accent);
        final stripe = Paint()
          ..color = const Color(0xFFC2C2C2)
          ..strokeWidth = 1;
        for (final x in [cx - w * 0.14, cx + w * 0.14]) {
          canvas.drawLine(Offset(x, t + 41), Offset(x, bottom), stripe);
        }
      case PenShape.shapePen:
        const w = 24.0;
        rect(cx - 1.6, t, cx + 1.6, t + 9, _dark);
        polygon([
          Offset(cx - 3, t + 9),
          Offset(cx + 3, t + 9),
          Offset(cx + w * 0.4, t + 30),
          Offset(cx - w * 0.4, t + 30),
        ], const Color(0xFF9E9E9E));
        rect(cx - w * 0.4, t + 30, cx + w * 0.4, bottom, accent);
        final glyph = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..color = Colors.white;
        canvas.drawPath(
          Path()..addPolygon([
            Offset(cx, t + 40),
            Offset(cx + 4.5, t + 48),
            Offset(cx - 4.5, t + 48),
          ], true),
          glyph,
        );
        canvas.drawCircle(Offset(cx, t + 58), 3.6, glyph);
      case PenShape.highlighterChisel:
        const w = 30.0;
        polygon([
          Offset(cx - w * 0.28, t + 18),
          Offset(cx + w * 0.28, t + 18),
          Offset(cx + w * 0.22, t + 2),
          Offset(cx - w * 0.22, t + 10),
        ], highlighted ? opaque : const Color(0xFFE0C9A0));
        polygon([
          Offset(cx - w * 0.3, t + 18),
          Offset(cx + w * 0.3, t + 18),
          Offset(cx + w * 0.48, t + 34),
          Offset(cx - w * 0.48, t + 34),
        ], _light, outline: true);
        rect(cx - w * 0.48, t + 34, cx + w * 0.48, bottom, const Color(0xFFE3E3E3));
        rect(cx - w * 0.48, t + 46, cx + w * 0.48, t + 54, accent);
      case PenShape.highlighterRound:
        const w = 22.0;
        canvas.drawRRect(
          RRect.fromLTRBAndCorners(
            cx - w * 0.22,
            t,
            cx + w * 0.22,
            t + 16,
            topLeft: const Radius.circular(w * 0.22),
            topRight: const Radius.circular(w * 0.22),
          ),
          fill..color = highlighted ? opaque : const Color(0xFFE0C9A0),
        );
        polygon([
          Offset(cx - w * 0.24, t + 14),
          Offset(cx + w * 0.24, t + 14),
          Offset(cx + w * 0.45, t + 32),
          Offset(cx - w * 0.45, t + 32),
        ], _light, outline: true);
        rect(cx - w * 0.45, t + 32, cx + w * 0.45, bottom, const Color(0xFFE3E3E3));
        rect(cx - w * 0.45, t + 44, cx + w * 0.45, t + 50, const Color(0xFF9E9E9E));
    }
  }

  /// A short wave above the tip in the pen's colour, like a test scribble.
  void _paintSample(Canvas canvas, double cx) {
    final y = top - 4;
    final highlighter =
        shape == PenShape.highlighterChisel ||
        shape == PenShape.highlighterRound;
    final paint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeCap = shape == PenShape.highlighterChisel
          ? StrokeCap.butt
          : StrokeCap.round
      ..strokeWidth = switch (shape) {
        PenShape.fountainPen => 2.6,
        PenShape.ballpointPen || PenShape.shapePen => 2.0,
        PenShape.pencil => 1.6,
        _ => 8,
      }
      ..color = highlighter
          ? color.withValues(alpha: 0.45)
          : shape == PenShape.pencil
          ? color.withValues(alpha: 0.8)
          : color.withValues(alpha: 1);
    if (shape == PenShape.shapePen) {
      canvas.drawPath(
        Path()..addPolygon([
          Offset(cx - 9, y - 2),
          Offset(cx + 9, y - 2),
          Offset(cx, y - 18),
        ], true),
        paint,
      );
      return;
    }
    canvas.drawPath(
      Path()
        ..moveTo(cx - 16, y - 2)
        ..cubicTo(cx - 10, y - 22, cx - 2, y - 22, cx, y - 10)
        ..cubicTo(cx + 2, y, cx + 10, y, cx + 16, y - 20),
      paint,
    );
  }

  @override
  bool shouldRepaint(PenDrawingPainter oldDelegate) =>
      oldDelegate.shape != shape ||
      oldDelegate.color != color ||
      oldDelegate.top != top ||
      oldDelegate.highlighted != highlighted ||
      oldDelegate.sample != sample;
}
