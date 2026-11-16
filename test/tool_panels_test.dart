import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/toolbar/tool_panels.dart';
import 'package:saber/components/toolbar/toolbar_layout.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import 'utils/test_mock_channel_handlers.dart';

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
    final previousAlignment = stows.workspaceToolbarAlignment.value;
    final previousLayout = stows.pageToolbarLayout.value;
    final previousTool = stows.lastTool.value;
    final previousFinger = stows.editorFingerDrawing.value;
    stows.workspaceToolbarAlignment.value = AxisDirection.up;
    stows.pageToolbarLayout.value = const [];
    // The editor starts with the last tool used, so a test that ends on the
    // eraser would otherwise hand it to the next one.
    stows.lastTool.value = stows.lastTool.defaultValue;
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.workspaceToolbarAlignment.value = previousAlignment;
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
          home: Editor(path: '/tool-panels', onSaveSnapshot: (_, _) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  Finder panel(String id) => find.byKey(ValueKey('tool-panel-$id'));

  testWidgets('the chosen pen opens its panel and a tap on the page only closes it', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    expect(editor.currentTool, isA<Pen>());
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    expect(panel('pen'), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-panel-stabiliser')), findsOneWidget);
    await tester.tapAt(const Offset(600, 1300));
    // It closes a moment later, so a second finger right after is swallowed too.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(panel('pen'), findsNothing);
    expect(editor.coreInfo.pages.first.strokes, isEmpty);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('an open panel stays with its own tool when the toolbar layout changes', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    expect(panel('eraser'), findsOneWidget);
    stows.pageToolbarLayout.value = const ['!pencil'];
    await tester.pumpAndSettle();
    expect(panel('eraser'), findsOneWidget);
    expect(panel('select'), findsNothing);
    await tester.tapAt(const Offset(600, 1300));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(panel('eraser'), findsNothing);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a toolbar tap goes through while the panel stays open', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toolbar-color-1')));
    await tester.pumpAndSettle();
    expect(panel('pen'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('toolbar-color-1')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the stabiliser changes the pen in hand', (tester) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    final slider = tester.getRect(
      find.byKey(const ValueKey('tool-panel-stabiliser')),
    );
    await tester.tapAt(
      Offset(slider.left + 24 + (slider.width - 48) * 0.2, slider.center.dy),
    );
    await tester.pumpAndSettle();
    expect((editor.currentTool as Pen).options.streamline, closeTo(0.2, 0.051));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the eraser opens its panel on the second tap and stays chosen', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Eraser>());
    expect(panel('eraser'), findsNothing);
    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Eraser>());
    expect(panel('eraser'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tool-panel-highlighter-only')));
    await tester.pumpAndSettle();
    expect(stows.eraseHighlighterOnly.value, isTrue);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the lasso panel picks the rectangle lasso and another tool closes it', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byTooltip('올가미'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('올가미'));
    await tester.pumpAndSettle();
    expect(panel('select'), findsOneWidget);
    await tester.tap(find.text('사각형 올가미'));
    await tester.pumpAndSettle();
    expect(stows.selectRectangle.value, isTrue);
    await tester.tap(find.byTooltip('형광펜'));
    await tester.pumpAndSettle();
    expect(panel('select'), findsNothing);
    await tester.tap(find.byTooltip('형광펜'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tool-panel-straight-line')), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-panel-stabiliser')), findsNothing);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the pen panel picks the pencil and the pen button keeps it', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    expect(find.text('만년필'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pen-type-pencil')));
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Pencil>());
    expect(find.text('연필'), findsOneWidget);
    expect(stows.lastPenFamily.value, ToolId.pencil);
    await tester.tap(find.byTooltip('형광펜'));
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Highlighter>());
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Pencil>());
    // Like StarNote, no separate pencil button unless the user adds it.
    expect(find.byTooltip('연필'), findsNothing);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the width shows millimetres and a swatch colours the pen', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    final pen = editor.currentTool as Pen;
    String shown() => tester
        .widget<Text>(find.byKey(const ValueKey('tool-panel-size-value')))
        .data!;
    expect(shown(), millimetres(pen.options.size));
    final slider = tester.getRect(find.byKey(const ValueKey('tool-panel-size')));
    await tester.tapAt(Offset(slider.right - 24, slider.center.dy));
    await tester.pumpAndSettle();
    expect(pen.options.size, pen.sizeMax);
    expect(shown(), '5.25mm');
    await tester.tap(find.byKey(const ValueKey('tool-panel-color-1')));
    await tester.pumpAndSettle();
    expect(pen.color, Color(toolbarQuickColors[1]));
    expect(stows.lastFountainPenColor.value, toolbarQuickColors[1]);
    // The chosen swatch again: the panel gives way to the full palette.
    await tester.tap(find.byKey(const ValueKey('tool-panel-color-1')));
    await tester.pumpAndSettle();
    expect(panel('pen'), findsNothing);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a pen kept in the pen box is picked up from the toolbar star', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pen-type-ballpointPen')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tool-panel-add-to-pen-box')));
    await tester.pumpAndSettle();
    expect(find.text('펜박스에 있음'), findsOneWidget);
    expect(PenBox.entries.single.toolId, ToolId.ballpointPen);

    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toolbar-pen-box')));
    await tester.pumpAndSettle();
    expect(panel('penBox'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pen-box-entry-0')));
    await tester.pumpAndSettle();
    expect(panel('penBox'), findsNothing);
    expect(editor.currentTool.toolId, ToolId.ballpointPen);

    await tester.tap(find.byKey(const ValueKey('toolbar-pen-box')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pen-box-remove-0')));
    await tester.pumpAndSettle();
    expect(PenBox.entries, isEmpty);
    expect(find.textContaining('펜박스에 추가'), findsOneWidget);
    editor.cancelAutosaveAndMarkSaved();
  });

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

    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('tool-panel-eraser-mode-lasso')),
    );
    await tester.pumpAndSettle();
    expect(stows.eraserMode.value, EraserMode.lasso);
    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    expect(panel('eraser'), findsNothing);

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

  testWidgets('leaving the text box gives back the pencil the pen button holds', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pen-type-pencil')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    expect(panel('pen'), findsNothing);
    await tester.tap(find.byTooltip('글상자'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('글상자'));
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Pencil>());
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    expect(find.text('연필'), findsOneWidget);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the pen button shows the pen in hand, not a stale kind', (
    tester,
  ) async {
    // Saved by an older run: the editor still starts with the fountain pen.
    stows.lastPenFamily.value = ToolId.pencil;
    final editor = await mountEditor(tester);
    expect(editor.currentTool.toolId, ToolId.fountainPen);
    expect(stows.lastPenFamily.value, ToolId.fountainPen);
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    expect(find.text('만년필'), findsOneWidget);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('on a landscape screen a tall panel stays under the toolbar', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    final button = tester.getRect(find.byTooltip('펜'));
    final shown = tester.getRect(panel('pen'));
    expect(shown.top, greaterThan(button.bottom));
    expect(shown.bottom, lessThanOrEqualTo(800));
    // The rest of the panel is reached by scrolling it.
    await tester.drag(
      find.descendant(
        of: panel('pen'),
        matching: find.byType(SingleChildScrollView),
      ),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    final button2 = tester.getRect(
      find.byKey(const ValueKey('tool-panel-add-to-pen-box')),
    );
    expect(button2.bottom, lessThanOrEqualTo(shown.bottom));
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
      expect(editor.coreInfo.pages, hasLength(2));
      editor.undo();
      await tester.pump();
      expect(editor.coreInfo.pages.expand((page) => page.strokes), hasLength(2));
      editor.cancelAutosaveAndMarkSaved();
    });
  }
}
