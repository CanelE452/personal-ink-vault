import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/select.dart';
import 'package:sbn/tool_id.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  final page = EditorPage(size: const Size(1000, 1400));
  Stroke stroke(ToolId tool, List<Offset> points) => Stroke(
    color: Colors.black,
    pressureEnabled: false,
    options: StrokeOptions(size: 4),
    pageIndex: 0,
    page: page,
    toolId: tool,
  )..addPoints(points);

  tearDown(() {
    stows.eraserSize.value = stows.eraserSize.defaultValue;
    stows.eraseHighlighterOnly.value = stows.eraseHighlighterOnly.defaultValue;
    stows.highlighterStraightLine.value =
        stows.highlighterStraightLine.defaultValue;
    stows.selectRectangle.value = stows.selectRectangle.defaultValue;
    stows.selectInk.value = stows.selectInk.defaultValue;
    stows.selectHighlighter.value = stows.selectHighlighter.defaultValue;
    stows.selectImages.value = stows.selectImages.defaultValue;
    stows.lastBallpointPenOptions.value =
        stows.lastBallpointPenOptions.defaultValue;
    stows.highlighterAxisLock.value = stows.highlighterAxisLock.defaultValue;
    stows.lastFountainPenColor.value = stows.lastFountainPenColor.defaultValue;
    stows.lastBallpointPenColor.value =
        stows.lastBallpointPenColor.defaultValue;
    stows.lastHighlighterColor.value = stows.lastHighlighterColor.defaultValue;
    stows.lastPencilOptions.value = stows.lastPencilOptions.defaultValue;
    stows.lastPencilColor.value = stows.lastPencilColor.defaultValue;
    stows.penBox.value = stows.penBox.defaultValue;
  });

  test('eraser size and highlighter-only follow the settings while the eraser is in hand', () {
    final eraser = Eraser();
    final ink = stroke(ToolId.ballpointPen, const [
      Offset(100, 100),
      Offset(200, 100),
    ]);
    final marker = stroke(ToolId.highlighter, const [
      Offset(100, 300),
      Offset(200, 300),
    ]);
    // About 28 px from the ink: outside the default size 10, inside 40.
    expect(eraser.checkForOverlappingStrokes(const Offset(150, 130), [ink]), isEmpty);
    stows.eraserSize.value = 40;
    expect(eraser.checkForOverlappingStrokes(const Offset(150, 130), [ink]), [ink]);
    stows.eraseHighlighterOnly.value = true;
    expect(
      eraser.checkForOverlappingStrokes(const Offset(150, 100), [ink, marker]),
      isEmpty,
    );
    expect(
      eraser.checkForOverlappingStrokes(const Offset(150, 300), [ink, marker]),
      [marker],
    );
    // An explicit size still wins.
    expect(Eraser(size: 3).size, 3);
  });

  test('rectangle lasso selects in any drag direction and honours the type filters', () {
    final select = Select.currentSelect;
    final ink = stroke(ToolId.ballpointPen, const [
      Offset(110, 110),
      Offset(150, 150),
      Offset(190, 190),
    ]);
    final marker = stroke(ToolId.highlighter, const [
      Offset(120, 180),
      Offset(180, 120),
    ]);
    final outside = stroke(ToolId.ballpointPen, const [
      Offset(400, 400),
      Offset(450, 450),
    ]);
    List<Stroke> drag(Offset from, Offset via, Offset to) {
      select.onDragStart(from, 0);
      select.onDragUpdate(via);
      select.onDragUpdate(to);
      select.onDragEnd([ink, marker, outside], const []);
      return select.selectResult.strokes;
    }

    stows.selectRectangle.value = true;
    // Up and to the left, through a point that would make a free lasso a sliver.
    expect(drag(const Offset(300, 300), const Offset(150, 140), const Offset(50, 50)), [
      ink,
      marker,
    ]);
    stows.selectHighlighter.value = false;
    expect(drag(const Offset(50, 50), const Offset(60, 290), const Offset(300, 300)), [ink]);
    stows.selectHighlighter.value = true;
    stows.selectInk.value = false;
    expect(drag(const Offset(50, 50), const Offset(60, 290), const Offset(300, 300)), [
      marker,
    ]);
  });

  test('straight highlighter keeps a line while drawing and survives a single tap', () {
    stows.highlighterStraightLine.value = true;
    final highlighter = Highlighter();
    highlighter.onDragStart(const Offset(100, 100), page, 0, null);
    highlighter.onDragUpdate(const Offset(150, 160), null);
    highlighter.onDragUpdate(const Offset(300, 103), null);
    // Snapped to horizontal, like a straightened line.
    expect(Pen.currentStroke!.points.map((point) => (point.dx, point.dy)), [
      (100.0, 100.0),
      (300.0, 100.0),
      (300.0, 100.0),
    ]);
    // While drawing, the drawn line already reaches the pen.
    expect(
      Pen.currentStroke!.lowQualityPolygon
          .map((point) => point.dx)
          .reduce((a, b) => a > b ? a : b),
      greaterThan(295),
    );
    expect(highlighter.onDragEnd()!.points, hasLength(3));
    highlighter.onDragStart(const Offset(10, 10), page, 0, null);
    expect(highlighter.onDragEnd()!.points, hasLength(1));
  });

  test('stroke stabilisation is saved per pen', () {
    final pen = Pen.ballpointPen();
    pen.setStreamline(0.2);
    expect(pen.options.streamline, 0.2);
    expect(stows.lastBallpointPenOptions.value.streamline, 0.2);
    expect(Pen.ballpointPen().options.streamline, 0.2);
    expect(stows.lastFountainPenOptions.value.streamline, isNot(0.2));
  });

  test('the loop eraser takes the strokes mostly inside its loop, once', () {
    final eraser = Eraser();
    final inside = stroke(ToolId.ballpointPen, const [
      Offset(120, 120),
      Offset(160, 150),
      Offset(200, 180),
    ]);
    // Only its first point is inside the loop: kept.
    final crossing = stroke(ToolId.ballpointPen, const [
      Offset(250, 120),
      Offset(400, 120),
      Offset(550, 120),
    ]);
    final marker = stroke(ToolId.highlighter, const [
      Offset(130, 200),
      Offset(200, 200),
    ]);
    List<Stroke> loop() {
      eraser.startLasso(const Offset(100, 100), 0);
      for (final point in const [
        Offset(260, 100),
        Offset(260, 260),
        Offset(100, 260),
      ]) {
        eraser.extendLasso(point);
      }
      return eraser.finishLasso([inside, crossing, marker]);
    }

    expect(loop(), [inside, marker]);
    expect(eraser.lassoPath, isNull);
    // onDragEnd reports them for the one undo step, then forgets them.
    expect(eraser.onDragEnd(), [inside, marker]);
    expect(eraser.onDragEnd(), isEmpty);
    stows.eraseHighlighterOnly.value = true;
    expect(loop(), [marker]);
    // A drag that never started a loop erases nothing.
    expect(Eraser().finishLasso([inside]), isEmpty);
  });

  test('horizontal/vertical keeps the straight highlighter on the closer axis', () {
    stows.highlighterStraightLine.value = true;
    stows.highlighterAxisLock.value = true;
    final highlighter = Highlighter();
    List<(double, double)> line(Offset to) {
      highlighter.onDragStart(Offset.zero, page, 0, null);
      highlighter.onDragUpdate(to, null);
      final points = [
        for (final point in Pen.currentStroke!.points) (point.dx, point.dy),
      ];
      highlighter.onDragEnd();
      return points;
    }

    // 11 degrees off: the plain straight line would keep the slope.
    expect(line(const Offset(100, 20)).last, (100.0, 0.0));
    expect(line(const Offset(10, 80)).last, (0.0, 80.0));
    stows.highlighterAxisLock.value = false;
    expect(line(const Offset(100, 20)).last, (100.0, 20.0));
  });

  test('a pen keeps its colour for the next pen of its kind', () {
    Pen.ballpointPen().setColor(const Color(0xffb63a3a));
    expect(Pen.ballpointPen().color, const Color(0xffb63a3a));
    expect(Pen.fountainPen().color, isNot(const Color(0xffb63a3a)));
    final orange = const Color(0xffffa94d).withAlpha(Highlighter.alpha);
    Highlighter().setColor(orange);
    expect(Highlighter().color, orange);
  });

  test('the pen box keeps one copy of a pen and gives back the same pen', () {
    final pencil = Pencil()
      ..setSize(7)
      ..setStreamline(0.3)
      ..setColor(const Color(0xff315fa0));
    final entry = PenBoxEntry.of(pencil);
    expect(PenBox.add(entry), isTrue);
    expect(PenBox.add(PenBoxEntry.of(pencil)), isFalse);
    expect(PenBox.entries, [entry]);
    expect(PenBoxEntry.fromJson(entry.toJson()), entry);

    final pen = entry.createPen();
    expect(pen, isA<Pencil>());
    expect(pen.options.size, 7);
    expect(pen.options.streamline, 0.3);

    // A width from an older range is brought into the pen's range.
    const wide = PenBoxEntry(
      toolId: ToolId.ballpointPen,
      color: 0xff000000,
      size: 80,
      streamline: 0.5,
    );
    expect(wide.createPen().options.size, 25);

    // The highlighter's colour is kept without its transparency.
    final marker = Highlighter()
      ..setColor(const Color(0xff7be07b).withAlpha(Highlighter.alpha));
    expect(PenBoxEntry.of(marker).color, 0xff7be07b);

    PenBox.remove(entry);
    expect(PenBox.entries, isEmpty);
    // Something the pen box did not write is skipped.
    stows.penBox.value = ['not json'];
    expect(PenBox.entries, isEmpty);
  });
}
