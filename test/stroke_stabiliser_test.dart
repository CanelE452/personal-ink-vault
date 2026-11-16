import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/stroke_stabiliser.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/data/tools/stroke_properties.dart';

double _distToPolyline(Offset p, List<Offset> line) {
  var best = double.infinity;
  for (var i = 0; i < line.length - 1; i++) {
    final a = line[i], b = line[i + 1];
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    final t = len2 == 0
        ? 0.0
        : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    final d = (p - (a + ab * t)).distance;
    if (d < best) best = d;
  }
  return best;
}

double _mean(Iterable<double> values) =>
    values.reduce((a, b) => a + b) / values.length;

/// A pen moving at 120 points a second: a big circle drawn slowly around some
/// text, or quick cursive loops. The noise is a 9 Hz hand tremor of 0.8 page
/// units plus 0.4 units of digitiser jitter.
List<Offset> _signal({required bool slow, required bool noisy}) {
  final random = Random(3);
  double gauss() {
    final u = 1 - random.nextDouble(), v = random.nextDouble();
    return sqrt(-2 * log(u)) * cos(2 * pi * v);
  }

  final phaseX = random.nextDouble() * 2 * pi;
  final phaseY = random.nextDouble() * 2 * pi;
  const hz = 120;
  final points = <Offset>[];
  for (var i = 0; i <= hz * (slow ? 6 : 1.5); i++) {
    final t = i / hz;
    var x = slow ? 500 + 150 * cos(0.4 * t) : 100 + 60 * t + 15 * cos(8 * pi * t);
    var y = slow ? 500 + 150 * sin(0.4 * t) : 300 + 15 * sin(8 * pi * t);
    if (noisy) {
      x += 0.8 * sin(18 * pi * t + phaseX) + 0.4 * gauss();
      y += 0.8 * sin(18 * pi * t + phaseY) + 0.4 * gauss();
    }
    points.add(Offset(x, y));
  }
  return points;
}

Pen _ballpoint(double stabiliser) => Pen(
  name: 'ballpoint',
  sizeMin: 1,
  sizeMax: 25,
  sizeStep: 1,
  icon: Pen.ballpointPenIcon,
  options: StrokeOptions(size: 5, streamline: stabiliser),
  pressureEnabled: false,
  color: Colors.black,
  toolId: .ballpointPen,
);

Stroke _draw(Pen pen, List<Offset> input, {double screenScale = 1}) {
  final page = EditorPage(size: const Size(1000, 1400));
  pen.onDragStart(input.first, page, 0, null, screenScale: screenScale);
  for (final point in input.skip(1)) {
    pen.onDragUpdate(point, null);
  }
  return pen.onDragEnd()!;
}

List<Offset> _points(Stroke stroke) => [
  for (final point in stroke.points) Offset(point.x, point.y),
];

void main() {
  setUpAll(() {
    FlavorConfig.setup();
    StrokeOptionsExtension.setDefaults();
  });

  test('at 50% the stabiliser takes most of the wobble out of a slow circle', () {
    final clean = _signal(slow: true, noisy: false);
    final noisy = _signal(slow: true, noisy: true);
    final smoothClean = _points(_draw(_ballpoint(0.5), clean));
    final smoothNoisy = _points(_draw(_ballpoint(0.5), noisy));
    final before = _mean([for (final p in noisy) _distToPolyline(p, clean)]);
    final after = _mean([
      for (final p in smoothNoisy) _distToPolyline(p, smoothClean),
    ]);
    // perfect_freehand's streamline at 0.5 left 83% of it.
    expect(after / before, lessThan(0.35));
  });

  test('at 50% quick handwriting keeps its shape', () {
    final clean = _signal(slow: false, noisy: false);
    final smooth = _points(_draw(_ballpoint(0.5), clean));
    final error = _mean([for (final p in smooth) _distToPolyline(p, clean)]);
    expect(error, lessThan(0.6));
  });

  test('the stroke starts where the pen touched down and ends where it lifted',
      () {
    final noisy = _signal(slow: false, noisy: true);
    final stroke = _draw(_ballpoint(1), noisy);
    expect(_points(stroke).first, noisy.first);
    expect(_points(stroke).last, noisy.last);
    // Nothing trails the pen while it moves either.
    final pen = _ballpoint(1);
    pen.onDragStart(noisy.first, EditorPage(size: const Size(1000, 1400)), 0,
        null);
    for (final point in noisy.skip(1).take(40)) {
      pen.onDragUpdate(point, null);
      expect(_points(Pen.currentStroke!).last, point);
    }
    pen.onDragEnd();
  });

  test('at 0% the stroke keeps the points the pen gave', () {
    final noisy = _signal(slow: false, noisy: true);
    expect(_points(_draw(_ballpoint(0), noisy)), noisy);
  });

  test('smoothing as the pen moves gives the stroke smoothing it at once', () {
    final raw = [
      for (final point in _signal(slow: false, noisy: true))
        PointVector(point.dx, point.dy, 0.5),
    ];
    final stabiliser = StrokeStabiliser(4);
    final drawn = <PointVector>[];
    for (final point in raw) {
      stabiliser.add(point, drawn);
    }
    final whole = StrokeStabiliser.smooth(raw, 4);
    expect(drawn.length, whole.length);
    for (var i = 0; i < whole.length; i++) {
      expect(drawn[i].x, closeTo(whole[i].x, 1e-9));
      expect(drawn[i].y, closeTo(whole[i].y, 1e-9));
      expect(drawn[i].pressure, raw[i].pressure);
    }
  });

  // A pen held still on the page: its points pile up in one spot.
  List<PointVector> resting() {
    final random = Random(7);
    return [
      for (var i = 0; i < 30; i++) PointVector(100 + i * 2.0, 100, 0.5),
      for (var i = 0; i < 400; i++)
        PointVector(
          160 + random.nextDouble() * 0.02,
          100 + random.nextDouble() * 0.02,
          0.3 + i / 1000,
        ),
      for (var i = 1; i <= 30; i++) PointVector(160 + i * 2.0, 100, 0.5),
    ];
  }

  test('a resting pen still smooths the same as the whole stroke at once', () {
    final raw = resting();
    final stabiliser = StrokeStabiliser(3);
    final drawn = <PointVector>[];
    for (final point in raw) {
      stabiliser.add(point, drawn);
    }
    final whole = StrokeStabiliser.smooth(raw, 3);
    expect(drawn.length, whole.length);
    for (var i = 0; i < whole.length; i++) {
      expect(drawn[i].x, closeTo(whole[i].x, 1e-9));
      expect(drawn[i].y, closeTo(whole[i].y, 1e-9));
    }
  });

  test('while the pen rests, a new point leaves the earlier points alone', () {
    final raw = resting().take(400).toList();
    final stabiliser = StrokeStabiliser(3);
    final drawn = <PointVector>[];
    for (final point in raw) {
      stabiliser.add(point, drawn);
    }
    final before = List.of(drawn);
    stabiliser.add(raw.last, drawn);
    // Only the last points around the pen are averaged again, not the
    // hundreds piled up behind it.
    var kept = 0;
    while (identical(drawn[kept], before[kept])) {
      kept++;
    }
    expect(kept, greaterThan(before.length - 60));
  });

  test('zoomed in, the same setting smooths over fewer page units', () {
    final noisy = _signal(slow: false, noisy: true);
    // 100% at twice the zoom is the same width on the page as 50% unzoomed.
    final zoomed = _points(_draw(_ballpoint(1), noisy, screenScale: 2));
    final unzoomed = _points(_draw(_ballpoint(0.5), noisy));
    expect(zoomed.length, unzoomed.length);
    for (var i = 0; i < zoomed.length; i++) {
      expect((zoomed[i] - unzoomed[i]).distance, lessThan(1e-9));
    }
  });

  test('new pen strokes add no perfect_freehand smoothing on top', () {
    final stroke = _draw(_ballpoint(0.5), _signal(slow: false, noisy: true));
    expect(stroke.options.streamline, 0);
  });

  test('the highlighter and the shape pen keep their own behaviour', () async {
    await stows.shapeRecognitionDelay.waitUntilRead();
    final noisy = _signal(slow: false, noisy: true);
    final highlighter = Highlighter()
      ..options = StrokeOptions(size: 30, streamline: 0.5);
    final highlighted = _draw(highlighter, noisy);
    expect(_points(highlighted), noisy);
    expect(highlighted.options.streamline, 0.5);
    final shapePen = ShapePen();
    final shaped = Stroke(
      color: Colors.black,
      pressureEnabled: false,
      options: shapePen.options.copyWith(),
      pageIndex: 0,
      page: EditorPage(size: const Size(1000, 1400)),
      toolId: .shapePen,
    );
    shapePen.onDragStart(noisy.first, EditorPage(size: const Size(1000, 1400)),
        0, null);
    shaped.addPoint(noisy.first);
    for (final point in noisy.skip(1)) {
      shapePen.onDragUpdate(point, null);
      shaped.addPoint(point);
    }
    expect(_points(Pen.currentStroke!), _points(shaped));
    Pen.currentStroke = null;
  });
}
