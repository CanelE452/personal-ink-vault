import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_drawing/path_drawing.dart';

import 'package:saber/components/kit/kit_icons.g.dart';
import 'package:saber/components/kit/kit_tokens.dart';

export 'package:saber/components/kit/kit_icons.g.dart';

/// A dashed line of an icon, as the export writes it.
final _dashedLine = RegExp(r'<path d="([^"]*)" stroke-dasharray="([^"]*)"/>');

/// The icons' drawing grid (the svg's viewBox).
const _grid = 24.0;

/// The width icon (`width`) for the size number [level] (1-100): the thin
/// and thick lines stay, the middle one is as wide as the level's step
/// (preview-v8k `barWidth`, line 2315).
String kitWidthDrawing(int level) {
  const lines = KitTokens.widthIconLines;
  final step = math.min(
    lines.length - 1,
    (level - 1) ~/ KitTokens.widthIconLevelsPerLine,
  );
  var line = 0;
  return KitIconName.width.svg.replaceAllMapped(
    RegExp('stroke-width="[^"]*"'),
    (m) => line++ == 1
        ? 'stroke-width="${lines[step].toStringAsFixed(1)}"'
        : m[0]!,
  );
}

/// Draws one icon of our set. Colour comes from [color] or the ambient
/// [IconTheme]. [selected] adds the accent fills (the chosen state).
class KitIcon extends StatelessWidget {
  const new(
    this.name, {
    super.key,
    this.size = KitTokens.toolbarIconSize,
    this.strokeWidth = KitTokens.toolbarIconStroke,
    this.color,
    this.selected = false,
    this.drawing,
  });

  final KitIconName name;
  final double size;
  final double strokeWidth;
  final Color? color;
  final bool selected;

  /// Drawn instead of [name]'s drawing, on the same 24 grid; [name] still
  /// names it (the width icon with the width in hand, [kitWidthDrawing]).
  final String? drawing;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? IconTheme.of(context).color ?? Colors.black;
    final body = drawing ?? (selected ? name.selectedSvg : name.svg);
    final dashed = [
      for (final m in _dashedLine.allMatches(body)) (m.group(1)!, m.group(2)!),
    ];
    final svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
        'stroke="currentColor" stroke-width="$strokeWidth" stroke-linecap="round" '
        'stroke-linejoin="round">'
        '${dashed.isEmpty ? body : body.replaceAll(_dashedLine, '')}</svg>';
    final picture = SvgPicture.string(
      svg,
      width: size,
      height: size,
      semanticsLabel: name.label,
      theme: SvgTheme(currentColor: ink),
    );
    if (dashed.isEmpty) return picture;
    // flutter_svg cuts a dash at that share of a curve's parameter, not of
    // its length, so on a curve its dashes fall elsewhere than the
    // browser's. The dashed lines (each icon's first line) are drawn here
    // along the measured path, under the rest as in the drawing.
    return CustomPaint(
      painter: _Dashes(dashed, ink, strokeWidth),
      child: picture,
    );
  }
}

class _Dashes extends CustomPainter {
  const new(this.lines, this.ink, this.strokeWidth);

  /// Each dashed line's path data and dash array.
  final List<(String, String)> lines;
  final Color ink;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / _grid, size.height / _grid);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = ink
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final (d, array) in lines) {
      final dashes = [for (final v in array.split(' ')) double.parse(v)];
      canvas.drawPath(
        dashPath(parseSvgPathData(d), dashArray: CircularIntervalList(dashes)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Dashes old) =>
      !listEquals(old.lines, lines) ||
      old.ink != ink ||
      old.strokeWidth != strokeWidth;
}
