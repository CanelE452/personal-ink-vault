import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The eraser on the editor's pages: the loop eraser, a pinch that stops an
/// unfinished loop, and erasing after an empty page. Moved from the old
/// tool_panels_test.dart when the 229 toolbar and its panels were deleted
/// (Task 19); the test names are unchanged.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  Future<EditorState> mountEditor(WidgetTester tester) async {
    final previousLayout = stows.pageToolbarLayout.value;
    final previousTool = stows.lastTool.value;
    final previousFinger = stows.editorFingerDrawing.value;
    stows.pageToolbarLayout.value = const [];
    // The editor starts with the last tool used, so a test that ends on the
    // eraser would otherwise hand it to the next one.
    stows.lastTool.value = stows.lastTool.defaultValue;
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.pageToolbarLayout.value = previousLayout;
      stows.lastTool.value = previousTool;
      stows.editorFingerDrawing.value = previousFinger;
      stows.eraseHighlighterOnly.value = false;
      stows.selectRectangle.value = false;
      stows.lastFountainPenOptions.value =
          stows.lastFountainPenOptions.defaultValue;
      stows.lastBallpointPenOptions.value =
          stows.lastBallpointPenOptions.defaultValue;
      stows.lastPencilOptions.value = stows.lastPencilOptions.defaultValue;
      for (final color in [
        stows.lastFountainPenColor,
        stows.lastBallpointPenColor,
        stows.lastPencilColor,
        stows.lastShapePenColor,
        stows.lastHighlighterColor,
      ]) {
        color.value = color.defaultValue;
      }
      stows.lastPenFamily.value = stows.lastPenFamily.defaultValue;
      stows.eraserMode.value = stows.eraserMode.defaultValue;
      stows.penBox.value = stows.penBox.defaultValue;
      // The pens in hand are shared between editors: start the next test
      // with fresh ones.
      Pen.currentPen = Pen.fountainPen();
      Pencil.currentPencil = Pencil();
      Highlighter.currentHighlighter = Highlighter();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          // The text box's toolbar needs these, as the app provides them.
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(path: '/eraser-page', onSaveSnapshot: (_, _) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  testWidgets('the loop eraser erases what the loop holds, in one undo step', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    Offset at(double x, double y) =>
        page.renderBox!.localToGlobal(Offset(x, y));
    Future<void> stylus(List<Offset> points) async {
      final gesture = await tester.startGesture(
        points.first,
        kind: PointerDeviceKind.stylus,
      );
      var time = 0;
      for (final point in points.skip(1)) {
        time += 20;
        await gesture.moveTo(point, timeStamp: Duration(milliseconds: time));
      }
      await gesture.up(timeStamp: Duration(milliseconds: time + 10));
      await tester.pump();
    }

    await stylus([at(300, 300), at(350, 305), at(400, 310)]);
    expect(page.strokes, hasLength(1));

    // the eraser's kinds are in the floating bar's chip (10th draft)
    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('floating-bar-eraser-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('eraser-kind-lasso')));
    await tester.pumpAndSettle();
    expect(stows.eraserMode.value, EraserMode.lasso);
    // a tap beside the window only closes it
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kit-eraser-type-panel')), findsNothing);

    await stylus([
      at(250, 250),
      at(450, 250),
      at(450, 360),
      at(250, 360),
      at(252, 252),
    ]);
    expect(page.strokes, isEmpty);
    expect(editor.currentTool, isA<Eraser>());
    editor.undo();
    await tester.pump();
    expect(page.strokes, hasLength(1));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a second finger stops an unfinished loop from erasing', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    Offset at(double x, double y) =>
        page.renderBox!.localToGlobal(Offset(x, y));
    final pen = await tester.startGesture(
      at(300, 300),
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveTo(at(350, 305), timeStamp: const Duration(milliseconds: 20));
    await pen.moveTo(at(400, 310), timeStamp: const Duration(milliseconds: 40));
    await pen.up(timeStamp: const Duration(milliseconds: 50));
    await tester.pump();
    expect(page.strokes, hasLength(1));

    stows.eraserMode.value = EraserMode.lasso;
    stows.editorFingerDrawing.value = true;
    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    final finger = await tester.startGesture(at(250, 250), pointer: 11);
    await finger.moveTo(
      at(450, 250),
      timeStamp: const Duration(milliseconds: 20),
    );
    await finger.moveTo(
      at(450, 360),
      timeStamp: const Duration(milliseconds: 40),
    );
    await finger.moveTo(
      at(250, 360),
      timeStamp: const Duration(milliseconds: 60),
    );
    // A second finger lands before the loop is closed: a pinch.
    final second = await tester.startGesture(at(600, 700), pointer: 12);
    await tester.pump(const Duration(milliseconds: 30));
    await second.moveTo(
      at(650, 760),
      timeStamp: const Duration(milliseconds: 90),
    );
    await finger.up(timeStamp: const Duration(milliseconds: 100));
    await second.up(timeStamp: const Duration(milliseconds: 110));
    await tester.pumpAndSettle();
    expect(page.strokes, hasLength(1));
    expect((editor.currentTool as Eraser).lassoPath, isNull);
    editor.cancelAutosaveAndMarkSaved();
  });

  for (final mode in EraserMode.values) {
    testWidgets('the ${mode.name} eraser can empty a page after an empty one', (
      tester,
    ) async {
      stows.eraserMode.value = mode;
      final editor = await mountEditor(tester);
      // Small pages, so four of them are on screen at once.
      tester.view.physicalSize = const Size(400, 4000);
      await tester.pumpAndSettle();
      editor.createPage(3);
      Stroke line(int index) => Stroke(
        color: Colors.black,
        pressureEnabled: false,
        options: Pen.defaultOptions.copyWith(),
        pageIndex: index,
        page: editor.coreInfo.pages[index],
        toolId: ToolId.ballpointPen,
      )..addPoints(const [Offset(300, 300), Offset(500, 300), Offset(700, 300)]);
      editor.coreInfo.pages[0].strokes.add(line(0));
      editor.coreInfo.pages[2].strokes.add(line(2));
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pumpAndSettle();
      // At this width the tools part scrolls on its own (StarNote's toolbar).
      await tester.ensureVisible(find.byTooltip('지우개'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('지우개'));
      await tester.pumpAndSettle();

      final page = editor.coreInfo.pages[2];
      final points = mode == EraserMode.stroke
          ? const [
              Offset(300, 300),
              Offset(500, 300),
              Offset(700, 300),
              Offset(800, 300),
            ]
          : const [
              Offset(250, 250),
              Offset(750, 250),
              Offset(750, 350),
              Offset(250, 350),
              Offset(250, 260),
            ];
      final gesture = await tester.startGesture(
        page.renderBox!.localToGlobal(points.first),
        kind: PointerDeviceKind.stylus,
      );
      var time = 0;
      for (final point in points.skip(1)) {
        time += 16;
        await gesture.moveTo(
          page.renderBox!.localToGlobal(point),
          timeStamp: Duration(milliseconds: time),
        );
      }
      await gesture.up(timeStamp: Duration(milliseconds: time + 10));
      await tester.pumpAndSettle();
      // Before, the page under the eraser was removed mid-drag (RangeError).
      expect(tester.takeException(), isNull);
      expect(editor.coreInfo.pages.expand((page) => page.strokes), hasLength(1));
      expect(
        editor.coreInfo.pages,
        hasLength(3),
        reason: 'the record holds the page it emptied',
      );
      expect(editor.coreInfo.pages[2], same(page));
      editor.undo();
      await tester.pump();
      expect(editor.coreInfo.pages.expand((page) => page.strokes), hasLength(2));
      editor.cancelAutosaveAndMarkSaved();
    });
  }
}
