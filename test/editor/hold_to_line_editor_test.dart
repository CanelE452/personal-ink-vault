import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/hold_to_line.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import '../utils/test_mock_channel_handlers.dart';

/// 「멈추면 직선」 in the editor: a pen that stays within 8 px for 0.5 s
/// while drawing makes the stroke a line from its first point; the end
/// follows the pen until it lifts. The page is at scale 1 here, so page
/// units are screen pixels; time is the test's own (tester.pump).
void main() {
  // the pencil draws with its shader
  setUpAll(PencilShader.init);
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  late EditorPage page;

  Future<EditorState> mountEditor(WidgetTester tester) async {
    final previousLayout = stows.pageToolbarLayout.value;
    final previousTool = stows.lastTool.value;
    stows.pageToolbarLayout.value = const [];
    stows.lastTool.value = stows.lastTool.defaultValue;
    const size = Size(1000, 1600);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.pageToolbarLayout.value = previousLayout;
      stows.lastTool.value = previousTool;
      stows.straightLineByPen.value = stows.straightLineByPen.defaultValue;
      stows.axisLockByPen.value = stows.axisLockByPen.defaultValue;
      stows.lastPenFamily.value = stows.lastPenFamily.defaultValue;
      Pen.currentPen = Pen.fountainPen();
      Pencil.currentPencil = Pencil();
      Highlighter.currentHighlighter = Highlighter();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: size),
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(
              path: '/hold-to-line',
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.state<EditorState>(find.byType(Editor));
    page = editor.coreInfo.pages.first;
    expect(page.renderBox!.getTransformTo(null).getMaxScaleOnAxis(), 1);
    return editor;
  }

  Offset at(double x, double y) => page.renderBox!.localToGlobal(Offset(x, y));

  List<Offset> pointsOf(Stroke stroke) => [
    for (final p in stroke.points) Offset(p.x, p.y),
  ];

  /// Puts the pen down at [first] and moves it through [rest], each move
  /// [step] after the last (page units, the page at scale 1).
  Future<TestGesture> drawTo(
    WidgetTester tester,
    Offset first,
    List<Offset> rest, {
    Duration step = Duration.zero,
  }) async {
    final gesture = await tester.startGesture(
      at(first.dx, first.dy),
      kind: PointerDeviceKind.stylus,
    );
    for (final point in rest) {
      await gesture.moveTo(at(point.dx, point.dy));
      await tester.pump(step);
    }
    return gesture;
  }

  /// A freehand zigzag from (300, 300) to (380, 360), each move past 8 px.
  const zigzag = [
    Offset(320, 330),
    Offset(340, 310),
    Offset(360, 345),
    Offset(380, 360),
  ];

  testWidgets('holding still for 0.5 s turns the stroke into a line from its '
      'first point', (tester) async {
    final editor = await mountEditor(tester);
    final gesture = await drawTo(tester, const Offset(300, 300), zigzag);
    final stroke = Pen.currentStroke!;
    final first = pointsOf(stroke).first;
    expect(first, const Offset(300, 300));
    expect(stroke.length, greaterThan(3));
    // small moves, within 8 px of where the pen stopped, do not count
    await gesture.moveTo(at(383, 362));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveTo(at(381, 364));
    await tester.pump(const Duration(milliseconds: 199));
    expect(stroke.length, greaterThan(3));
    // the timer redraws the stroke, not the editor
    var editorBuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is Editor) editorBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    // the count can fail: a sure editor build is seen (no time passes, so
    // the timer, 1 ms away, does not fire yet)
    tester.element(find.byType(Editor)).markNeedsBuild();
    await tester.pump(Duration.zero);
    expect(editorBuilds, greaterThan(0));
    expect(pointsOf(stroke).length, greaterThan(3));
    editorBuilds = 0;
    await tester.pump(const Duration(milliseconds: 1));
    debugOnRebuildDirtyWidget = null;
    expect(editorBuilds, 0);
    expect(pointsOf(stroke), [
      first,
      const Offset(381, 364),
      const Offset(381, 364),
    ]);
    await gesture.up();
    await tester.pump();
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('holding at touch-down then writing keeps the freehand stroke', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final gesture = await drawTo(tester, const Offset(300, 300), const []);
    // the pen rests where it touched down, with a 1 px wobble
    await gesture.moveTo(at(301, 300));
    await tester.pump(const Duration(milliseconds: 600));
    for (final point in zigzag) {
      await gesture.moveTo(at(point.dx, point.dy));
    }
    await gesture.up();
    await tester.pump();
    final stroke = page.strokes.single;
    expect(stroke.length, greaterThan(3));
    expect(pointsOf(stroke).first, const Offset(300, 300));
    expect(pointsOf(stroke).last, zigzag.last);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('moving after the hold moves only the line end', (tester) async {
    final editor = await mountEditor(tester);
    final gesture = await drawTo(tester, const Offset(300, 300), zigzag);
    final stroke = Pen.currentStroke!;
    final first = pointsOf(stroke).first;
    expect(first, const Offset(300, 300));
    await tester.pump(holdToLineDelay);
    expect(stroke.length, 3);
    await gesture.moveTo(at(450, 520));
    await tester.pump();
    expect(pointsOf(stroke), [
      first,
      const Offset(450, 520),
      const Offset(450, 520),
    ]);
    await gesture.moveTo(at(200, 470));
    await tester.pump();
    expect(pointsOf(stroke), [
      first,
      const Offset(200, 470),
      const Offset(200, 470),
    ]);
    await gesture.up();
    await tester.pump();
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('lifting fixes the line at the lift point', (tester) async {
    final editor = await mountEditor(tester);
    final gesture = await drawTo(tester, const Offset(300, 300), zigzag);
    final first = pointsOf(Pen.currentStroke!).first;
    expect(first, const Offset(300, 300));
    await tester.pump(holdToLineDelay);
    await gesture.moveTo(at(420, 470));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    final line = page.strokes.single;
    expect(pointsOf(line), [
      first,
      const Offset(420, 470),
      const Offset(420, 470),
    ]);
    expect(line.options.isComplete, isTrue);
    expect(Pen.currentStroke, isNull);
    // nothing waits on a lifted pen
    await tester.pump(holdToLineDelay * 2);
    expect(pointsOf(page.strokes.single), pointsOf(line));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('hold to line works with straight line off', (tester) async {
    final editor = await mountEditor(tester);
    editor.currentTool = Pencil.currentPencil;
    expect(straightLineOf(KitPenKind.pencil), isFalse);
    final gesture = await drawTo(tester, const Offset(300, 300), zigzag);
    final first = pointsOf(Pen.currentStroke!).first;
    expect(first, const Offset(300, 300));
    await tester.pump(holdToLineDelay);
    await gesture.up();
    await tester.pump();
    expect(pointsOf(page.strokes.single), [
      first,
      const Offset(380, 360),
      const Offset(380, 360),
    ]);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('moving more than 8 px before 0.5 s keeps the freehand stroke', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    // a move of 9 px every 0.3 s, for 2.4 s
    final gesture = await drawTo(tester, const Offset(300, 300), [
      for (var i = 1; i <= 8; i++)
        Offset(300 + 9.0 * i, 300 + (i.isEven ? 3 : 0)),
    ], step: const Duration(milliseconds: 300));
    expect(Pen.currentStroke!.length, greaterThan(3));
    await gesture.up();
    await tester.pump();
    expect(page.strokes.single.length, greaterThan(3));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a held line is one undo step', (tester) async {
    final editor = await mountEditor(tester);
    expect(editor.history.canUndo, isFalse);
    final gesture = await drawTo(tester, const Offset(300, 300), zigzag);
    await tester.pump(holdToLineDelay);
    await gesture.moveTo(at(420, 470));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    final line = page.strokes.single;
    expect(editor.history.canUndo, isTrue);
    editor.undo();
    await tester.pump();
    expect(page.strokes, isEmpty);
    expect(editor.history.canUndo, isFalse);
    editor.redo();
    await tester.pump();
    expect(page.strokes.single, same(line));
    expect(line.length, 3);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets("the pen's 수평/수직 keeps the held line on an axis only when "
      'it is on', (tester) async {
    final editor = await mountEditor(tester);
    // 11 degrees off horizontal: a plain line keeps its slope
    Future<Offset> heldEnd() async {
      final gesture = await drawTo(tester, const Offset(300, 300), [
        const Offset(330, 320),
        const Offset(360, 300),
        const Offset(400, 320),
      ]);
      await tester.pump(holdToLineDelay);
      await gesture.up();
      await tester.pump();
      return pointsOf(page.strokes.last).last;
    }

    expect(await heldEnd(), const Offset(400, 320));
    // 수평/수직 alone is not usable (its straight line is off): no axis
    setAxisLock(KitPenKind.fountain, true);
    expect(await heldEnd(), const Offset(400, 320));
    setStraightLine(KitPenKind.fountain, true);
    expect(await heldEnd(), const Offset(400, 300));
    // another pen's 수평/수직 does not count
    setAxisLock(KitPenKind.fountain, false);
    setStraightLine(KitPenKind.pencil, true);
    setAxisLock(KitPenKind.pencil, true);
    expect(await heldEnd(), const Offset(400, 320));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the shape pen does not turn a held stroke into a line', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    editor.currentTool = ShapePen();
    final gesture = await drawTo(tester, const Offset(300, 300), zigzag);
    final stroke = Pen.currentStroke!;
    final drawn = pointsOf(stroke);
    expect(drawn.length, greaterThan(3));
    await tester.pump(holdToLineDelay * 2);
    expect(pointsOf(stroke), drawn);
    await gesture.moveTo(at(450, 520));
    await tester.pump();
    expect(stroke.length, greaterThan(drawn.length));
    await gesture.up();
    await tester.pump();
    editor.cancelAutosaveAndMarkSaved();
  });
}
