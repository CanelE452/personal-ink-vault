import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_canvas_painter.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:sbn/tool_id.dart';

const _pageSize = Size(600, 600);

/// The pixels of a painted page.
class _Pixels {
  const new(this.bytes, this.width);

  final Uint8List bytes;
  final int width;

  /// The red channel of the pixel (0 black, 255 white; the test strokes are
  /// grey or black, or the red channel is compared between renders).
  int red(int x, int y) => bytes[(y * width + x) * 4];
  int green(int x, int y) => bytes[(y * width + x) * 4 + 1];

  /// How dark the pixel is, 0 (white) to 255 (black).
  int ink(int x, int y) => 255 - green(x, y);

  /// The summed darkness of a rectangle.
  int inkIn(Rect rect) {
    var sum = 0;
    for (var y = rect.top.floor(); y < rect.bottom.ceil(); y++) {
      for (var x = rect.left.floor(); x < rect.right.ceil(); x++) {
        sum += ink(x, y);
      }
    }
    return sum;
  }

  /// The number of pixels in a rectangle that are darker than [level].
  int darkCount(Rect rect, {int level = 128}) {
    var count = 0;
    for (var y = rect.top.floor(); y < rect.bottom.ceil(); y++) {
      for (var x = rect.left.floor(); x < rect.right.ceil(); x++) {
        if (ink(x, y) > level) count++;
      }
    }
    return count;
  }
}

Stroke _stroke(
  EditorPage page,
  ToolId tool,
  List<Offset> points, {
  Color color = Colors.black,
  double size = 6,
  StrokeStyle style = const StrokeStyle(),
  double? pressure = 0.5,
  bool pressureEnabled = true,
}) {
  final stroke = Stroke(
    color: color,
    pressureEnabled: pressureEnabled,
    options: StrokeOptions(size: size, smoothing: 0, streamline: 0),
    pageIndex: 0,
    page: page,
    toolId: tool,
    style: style,
  );
  for (final p in points) {
    stroke.addPoint(p, pressure);
  }
  stroke.options.isComplete = true;
  return stroke;
}

/// A straight line from [a] to [b] with a point every 5 px.
List<Offset> _line(Offset a, Offset b) {
  final steps = ((b - a).distance / 5).ceil();
  return [for (var i = 0; i <= steps; i++) Offset.lerp(a, b, i / steps)!];
}

Future<_Pixels> _render(
  WidgetTester tester,
  EditorPage page,
  List<Stroke> strokes, {
  double scale = 1,
  Stroke? current,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & _pageSize, Paint()..color = Colors.white);
  CanvasPainter(
    strokes: strokes,
    laserStrokes: const [],
    currentStroke: current,
    currentSelection: null,
    primaryColor: Colors.blue,
    page: page,
    showPageIndicator: false,
    pageIndex: 0,
    totalPages: 1,
    currentScale: scale,
    defaultTextStyle: const TextStyle(),
  ).paint(canvas, _pageSize);
  final picture = recorder.endRecording();
  final pixels = await tester.runAsync(() async {
    final image = await picture.toImage(600, 600);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  picture.dispose();
  return _Pixels(pixels!, 600);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await PencilShader.init();
  });

  late EditorPage page;
  setUp(() => page = EditorPage(size: _pageSize));
  tearDown(() => page.dispose());

  final across = _line(const Offset(100, 100), const Offset(240, 240));

  testWidgets('a highlighter at alpha 200 is darker than one at the default', (
    tester,
  ) async {
    final line = _line(const Offset(100, 100), const Offset(500, 100));
    final base = await _render(tester, page, [
      _stroke(page, ToolId.highlighter, line, size: 40, color: Colors.blue),
    ]);
    final same = await _render(tester, page, [
      _stroke(
        page,
        ToolId.highlighter,
        line,
        size: 40,
        color: Colors.blue,
        style: const StrokeStyle(alpha: 100),
      ),
    ]);
    final dark = await _render(tester, page, [
      _stroke(
        page,
        ToolId.highlighter,
        line,
        size: 40,
        color: Colors.blue,
        style: const StrokeStyle(alpha: 200),
      ),
    ]);
    // the red channel falls as blue ink is added over white
    expect(base.red(300, 100), lessThan(255));
    expect(same.red(300, 100), base.red(300, 100));
    expect(dark.red(300, 100), lessThan(base.red(300, 100) - 40));
  });

  for (final shader in [true, false]) {
    testWidgets('a pencil at alpha 128 is lighter than at 255, '
        '${shader ? 'with' : 'without'} the shader', (tester) async {
      final line = _line(const Offset(100, 100), const Offset(500, 100));
      Future<_Pixels> draw(int alpha) => _render(tester, page, [
        _stroke(
          page,
          ToolId.pencil,
          line,
          size: 10,
          style: StrokeStyle(alpha: alpha),
        ),
      ], scale: shader ? 1 : 0.5);
      final full = await draw(255);
      final half = await draw(128);
      const area = Rect.fromLTWH(120, 90, 360, 20);
      expect(full.inkIn(area), greaterThan(0));
      expect(half.inkIn(area), lessThan(full.inkIn(area) * 0.7));
      expect(half.inkIn(area), greaterThan(full.inkIn(area) * 0.3));
    });
  }

  testWidgets('a dashed fine pen shows gaps', (tester) async {
    final line = _line(const Offset(50, 100), const Offset(550, 100));
    int gaps(_Pixels p) {
      var count = 0;
      var inGap = false;
      for (var x = 60; x < 540; x++) {
        final light = p.ink(x, 100) < 60;
        if (light && !inGap) count++;
        inGap = light;
      }
      return count;
    }

    Future<_Pixels> draw(KitPenDash dash) => _render(tester, page, [
      _stroke(
        page,
        ToolId.ballpointPen,
        line,
        style: StrokeStyle(lineStyle: dash),
      ),
    ]);
    expect(gaps(await draw(KitPenDash.solid)), 0);
    expect(gaps(await draw(KitPenDash.dash)), greaterThan(10));
    expect(gaps(await draw(KitPenDash.dot)), greaterThan(10));
  });

  testWidgets('a thin line style draws at half the width', (tester) async {
    final line = _line(const Offset(50, 100), const Offset(550, 100));
    Future<int> darkAt(KitPenDash dash) async {
      final p = await _render(tester, page, [
        _stroke(
          page,
          ToolId.ballpointPen,
          line,
          size: 8,
          style: StrokeStyle(lineStyle: dash),
        ),
      ]);
      return p.inkIn(const Rect.fromLTWH(100, 80, 400, 40));
    }

    final solid = await darkAt(KitPenDash.solid);
    final thin = await darkAt(KitPenDash.thin);
    expect(thin, inInclusiveRange(solid * 0.4, solid * 0.6));
  });

  testWidgets('a calligraphy stroke is thicker across the nib than along it', (
    tester,
  ) async {
    // the nib points up and to the right; a line down and to the right goes
    // across it, a line up and to the right goes along it
    final along = _line(const Offset(100, 500), const Offset(240, 360));
    final p = await _render(tester, page, [
      _stroke(
        page,
        ToolId.calligraphyPen,
        across,
        size: 12,
        style: const StrokeStyle(nib: InkNib.chisel, nibAngle: 45),
      ),
      _stroke(
        page,
        ToolId.calligraphyPen,
        along,
        size: 12,
        style: const StrokeStyle(nib: InkNib.chisel, nibAngle: 45),
      ),
    ]);
    final thick = p.darkCount(const Rect.fromLTWH(60, 60, 240, 240));
    final thin = p.darkCount(const Rect.fromLTWH(60, 320, 240, 240));
    expect(thin, greaterThan(100));
    expect(thick, greaterThan(thin * 2.5));
  });

  testWidgets('a nib along the travel still shows a line', (tester) async {
    // 0 degrees is a horizontal nib: a horizontal line makes zero-area quads
    final line = _line(const Offset(100, 100), const Offset(300, 100));
    final p = await _render(tester, page, [
      _stroke(
        page,
        ToolId.calligraphyPen,
        line,
        size: 12,
        style: const StrokeStyle(nib: InkNib.chisel, nibAngle: 0),
      ),
    ]);
    expect(p.ink(200, 100), greaterThan(200));
    expect(p.ink(200, 99), greaterThan(60));
    expect(
      p.darkCount(const Rect.fromLTWH(100, 90, 200, 20)),
      greaterThan(300),
    );
  });

  testWidgets('a tap with a chisel nib leaves a mark', (tester) async {
    final p = await _render(tester, page, [
      _stroke(
        page,
        ToolId.calligraphyPen,
        [const Offset(200, 200)],
        size: 20,
        style: const StrokeStyle(nib: InkNib.chisel, nibAngle: 45),
      ),
    ]);
    expect(p.darkCount(const Rect.fromLTWH(170, 170, 60, 60)), greaterThan(20));
  });

  testWidgets('two highlighters of one colour at two opacities draw as two '
      'layers', (tester) async {
    final horizontal = _line(const Offset(100, 100), const Offset(500, 100));
    final vertical = _line(const Offset(300, 50), const Offset(300, 300));
    Stroke a() => _stroke(
      page,
      ToolId.highlighter,
      horizontal,
      size: 40,
      color: Colors.blue,
    );
    Stroke b() => _stroke(
      page,
      ToolId.highlighter,
      vertical,
      size: 40,
      color: Colors.blue,
      style: const StrokeStyle(alpha: 200),
    );
    final onlyA = await _render(tester, page, [a()]);
    final onlyB = await _render(tester, page, [b()]);
    final both = await _render(tester, page, [a(), b()]);
    // away from the crossing each keeps its own opacity
    expect(both.red(450, 100), onlyA.red(450, 100));
    expect(both.red(300, 250), onlyB.red(300, 250));
    // where they cross the ink is darker than either alone
    expect(both.red(300, 100), lessThan(onlyB.red(300, 100) - 10));
    expect(both.red(300, 100), lessThan(onlyA.red(300, 100) - 10));
  });

  testWidgets('highlighters of one colour and one opacity stay one layer', (
    tester,
  ) async {
    // the old behaviour: one layer per colour, so a crossing is no darker
    final horizontal = _line(const Offset(100, 100), const Offset(500, 100));
    final vertical = _line(const Offset(300, 50), const Offset(300, 300));
    final p = await _render(tester, page, [
      _stroke(
        page,
        ToolId.highlighter,
        horizontal,
        size: 40,
        color: Colors.blue,
      ),
      _stroke(page, ToolId.highlighter, vertical, size: 40, color: Colors.blue),
    ]);
    expect(p.red(300, 100), p.red(450, 100));
  });

  group('the stroke being drawn looks like the finished stroke', () {
    final line = _line(const Offset(100, 100), const Offset(500, 100));

    Future<void> same(
      WidgetTester tester,
      Stroke Function() make,
      Rect area,
    ) async {
      final drawing = await _render(tester, page, [], current: make());
      final done = await _render(tester, page, [make()]);
      expect(drawing.inkIn(area), greaterThan(0));
      // a layer and a direct fill round the colour differently by a count or two
      expect(
        drawing.inkIn(area),
        closeTo(done.inkIn(area), done.inkIn(area) * 0.001),
      );
    }

    const area = Rect.fromLTWH(60, 60, 480, 80);

    testWidgets('a highlighter at the default opacity', (tester) async {
      // the pen's colour carries the default opacity, as the tool sets it
      await same(
        tester,
        () => _stroke(
          page,
          ToolId.highlighter,
          line,
          size: 40,
          color: Colors.blue.withAlpha(100),
        ),
        area,
      );
    });

    testWidgets('a highlighter at alpha 200', (tester) async {
      await same(
        tester,
        () => _stroke(
          page,
          ToolId.highlighter,
          line,
          size: 40,
          color: Colors.blue.withAlpha(100),
          style: const StrokeStyle(alpha: 200),
        ),
        area,
      );
    });

    testWidgets('a dashed fine pen', (tester) async {
      await same(
        tester,
        () => _stroke(
          page,
          ToolId.ballpointPen,
          line,
          style: const StrokeStyle(lineStyle: KitPenDash.dash),
        ),
        area,
      );
    });

    testWidgets('a calligraphy stroke', (tester) async {
      await same(
        tester,
        () => _stroke(
          page,
          ToolId.calligraphyPen,
          across,
          size: 12,
          style: const StrokeStyle(nib: InkNib.chisel, nibAngle: 45),
        ),
        const Rect.fromLTWH(60, 60, 240, 240),
      );
    });

    testWidgets('a pen at alpha 128', (tester) async {
      await same(
        tester,
        () => _stroke(
          page,
          ToolId.fountainPen,
          line,
          size: 10,
          style: const StrokeStyle(alpha: 128),
        ),
        area,
      );
    });
  });

  testWidgets('a dashed stroke zoomed out still shows gaps', (tester) async {
    final line = _line(const Offset(50, 100), const Offset(550, 100));
    final p = await _render(tester, page, [
      _stroke(
        page,
        ToolId.ballpointPen,
        line,
        style: const StrokeStyle(lineStyle: KitPenDash.dash),
      ),
    ], scale: 0.5);
    var gaps = 0;
    var inGap = false;
    for (var x = 60; x < 540; x++) {
      final light = p.ink(x, 100) < 60;
      if (light && !inGap) gaps++;
      inGap = light;
    }
    expect(gaps, greaterThan(10));
  });

  test('a dashed stroke has a solid low quality path for selecting', () {
    final stroke = _stroke(
      page,
      ToolId.ballpointPen,
      _line(const Offset(100, 100), const Offset(300, 100)),
      size: 10,
      style: const StrokeStyle(lineStyle: KitPenDash.dash),
    );
    final bounds = stroke.lowQualityPath.getBounds();
    expect(bounds.height, greaterThan(8));
    expect(stroke.lowQualityPath.contains(const Offset(200, 100)), isTrue);
  });

  test('the hit polygon of a calligraphy stroke follows the stroke', () {
    final stroke = _stroke(
      page,
      ToolId.calligraphyPen,
      _line(const Offset(100, 100), const Offset(300, 100)),
      size: 12,
      style: const StrokeStyle(nib: InkNib.chisel, nibAngle: 45),
    );
    final polygon = stroke.lowQualityPolygon;
    expect(polygon, isNotEmpty);
    final xs = polygon.map((p) => p.dx);
    expect(xs.reduce(math.min), lessThan(101));
    expect(xs.reduce(math.max), greaterThan(299));
    // nothing farther from the line than the nib reaches
    expect(
      polygon.map((p) => (p.dy - 100).abs()).reduce(math.max),
      lessThan(8),
    );
    expect(stroke.lowQualityPath.contains(const Offset(200, 100)), isTrue);
    expect(stroke.lowQualityPath.contains(const Offset(200, 130)), isFalse);
  });

  test('a brush stroke tapers at both ends', () {
    final stroke = _stroke(
      page,
      ToolId.brush,
      _line(const Offset(100, 100), const Offset(400, 100)),
      size: 30,
      pressure: null,
      pressureEnabled: false,
    );
    int heightAt(double x) {
      var count = 0;
      for (var y = 60.0; y < 140; y += 0.5) {
        if (stroke.highQualityPath.contains(Offset(x, y))) count++;
      }
      return count;
    }

    expect(heightAt(250), greaterThan(0));
    expect(heightAt(125), lessThan(heightAt(250) * 0.8));
    expect(heightAt(375), lessThan(heightAt(250) * 0.8));
  });
}
