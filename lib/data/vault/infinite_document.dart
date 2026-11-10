import 'dart:math' as math;
import 'dart:ui';

enum InfiniteInkTool { pen, highlighter }

class InfinitePoint {
  final double x;
  final double y;
  final double pressure;
  const new(this.x, this.y, {this.pressure = 1});
  Offset get offset => Offset(x, y);

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'pressure': pressure};

  factory fromJson(Map<String, dynamic> json) {
    final x = _number(json['x']);
    final y = _number(json['y']);
    final pressure = _number(json['pressure']);
    if (pressure < 0 || pressure > 1)
      throw const FormatException('Invalid ink pressure');
    return InfinitePoint(x, y, pressure: pressure);
  }
}

class InfiniteStroke {
  final String id;
  final InfiniteInkTool tool;
  final int color;
  final double width;
  final List<InfinitePoint> points;
  new({
    required this.id,
    required this.tool,
    required this.color,
    required this.width,
    required List<InfinitePoint> points,
  }) : points = List.unmodifiable(points) {
    if (id.isEmpty ||
        color < 0 ||
        color > 0xffffffff ||
        !width.isFinite ||
        width <= 0 ||
        points.isEmpty)
      throw const FormatException('Invalid infinite stroke');
    for (final point in points) {
      if (!point.x.isFinite ||
          !point.y.isFinite ||
          !point.pressure.isFinite ||
          point.pressure < 0 ||
          point.pressure > 1)
        throw const FormatException('Invalid infinite point');
    }
  }

  late final Rect bounds = _calculateBounds();

  Rect _calculateBounds() {
    var left = points.first.x;
    var right = left;
    var top = points.first.y;
    var bottom = top;
    for (final point in points.skip(1)) {
      left = math.min(left, point.x);
      right = math.max(right, point.x);
      top = math.min(top, point.y);
      bottom = math.max(bottom, point.y);
    }
    return Rect.fromLTRB(left, top, right, bottom).inflate(width / 2);
  }

  InfiniteStroke translated(Offset delta) => InfiniteStroke(
    id: id,
    tool: tool,
    color: color,
    width: width,
    points: [
      for (final point in points)
        InfinitePoint(
          point.x + delta.dx,
          point.y + delta.dy,
          pressure: point.pressure,
        ),
    ],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'tool': tool.name,
    'color': color,
    'width': width,
    'points': [for (final point in points) point.toJson()],
  };

  factory fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        json['color'] is! int ||
        json['points'] is! List)
      throw const FormatException('Invalid infinite stroke');
    final tools = InfiniteInkTool.values.where(
      (tool) => tool.name == json['tool'],
    );
    if (tools.isEmpty) throw const FormatException('Unknown infinite ink tool');
    return InfiniteStroke(
      id: json['id'] as String,
      tool: tools.single,
      color: json['color'] as int,
      width: _number(json['width']),
      points: [
        for (final point in json['points'] as List)
          InfinitePoint.fromJson(_object(point)),
      ],
    );
  }
}

class InfiniteDocument {
  final List<InfiniteStroke> strokes;
  const new empty() : strokes = const [];
  new({required List<InfiniteStroke> strokes})
    : strokes = List.unmodifiable(strokes) {
    if (strokes.map((stroke) => stroke.id).toSet().length != strokes.length)
      throw const FormatException('Duplicate infinite stroke ID');
  }
  factory fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['strokes'] is! List)
      throw const FormatException('Unsupported infinite document');
    return InfiniteDocument(
      strokes: [
        for (final stroke in json['strokes'] as List)
          InfiniteStroke.fromJson(_object(stroke)),
      ],
    );
  }
  Map<String, dynamic> toJson() => {
    'version': 1,
    'strokes': [for (final stroke in strokes) stroke.toJson()],
  };
  Iterable<InfiniteStroke> visibleStrokes(Rect viewport) =>
      strokes.where((stroke) => stroke.bounds.overlaps(viewport));
}

class InfiniteViewport {
  final Offset offset;
  final double scale;
  const new({this.offset = Offset.zero, this.scale = 1}) : assert(scale > 0);
  factory fromJson(Map<String, dynamic> json) {
    final scale = _number(json['scale']);
    if (scale < .05 || scale > 16)
      throw const FormatException('Invalid view scale');
    return InfiniteViewport(
      offset: Offset(_number(json['x']), _number(json['y'])),
      scale: scale,
    );
  }
  Map<String, double> toJson() => {
    'x': offset.dx,
    'y': offset.dy,
    'scale': scale,
  };
  Offset screenToWorld(Offset point) => (point - offset) / scale;
  Offset worldToScreen(Offset point) => point * scale + offset;
  InfiniteViewport pan(Offset delta) =>
      InfiniteViewport(offset: offset + delta, scale: scale);
  InfiniteViewport zoomAt(Offset focal, double factor) {
    if (!factor.isFinite || factor <= 0)
      throw const FormatException('Invalid zoom factor');
    final nextScale = (scale * factor).clamp(.05, 16.0).toDouble();
    return InfiniteViewport(
      offset: focal - screenToWorld(focal) * nextScale,
      scale: nextScale,
    );
  }
}

double _number(Object? value) {
  if (value is! num || !value.isFinite)
    throw const FormatException('Expected finite ink number');
  return value.toDouble();
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>)
    throw const FormatException('Expected ink object');
  return value;
}
