import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/toolbar/ink_width_presets.dart';
import 'package:saber/components/toolbar/size_picker.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import '../utils/test_mock_channel_handlers.dart';

const _group = ValueKey('toolbar-quick-ink-widths');
const _slider = ValueKey('pen-size-slider');
Finder _preset(int index) => find.byKey(ValueKey('ink-width-preset-$index'));

Future<void> _dragToMiddle(WidgetTester tester) async {
  final bounds = tester.getRect(find.byKey(_slider));
  final gesture = await tester.startGesture(
    Offset(bounds.left + 15, bounds.center.dy),
  );
  await gesture.moveTo(bounds.center);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  Future<EditorState> mount(
    WidgetTester tester, {
    required TargetPlatform platform,
    required double editorWidth,
  }) async {
    final priorTool = stows.lastTool.value;
    final priorPen = Pen.currentPen;
    final priorStroke = Pen.currentStroke;
    final priorOptions = stows.lastBallpointPenOptions.value;
    final priorAlignment = stows.editorToolbarAlignment.value;
    stows.lastTool.value = .ballpointPen;
    stows.lastBallpointPenOptions.value = Pen.ballpointPenOptions;
    stows.editorToolbarAlignment.value = AxisDirection.left;
    Pen.currentPen = Pen.ballpointPen();
    tester.view.physicalSize = const Size(1120, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.lastTool.value = priorTool;
      stows.lastBallpointPenOptions.value = priorOptions;
      stows.editorToolbarAlignment.value = priorAlignment;
      Pen.currentPen = priorPen;
      Pen.currentStroke = priorStroke;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(platform: platform),
          home: Center(
            child: SizedBox(
              width: editorWidth,
              height: 720,
              child: Editor(
                path: '/width-presets',
                showDocumentHeader: false,
                onSaveSnapshot: (_, _) async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  test('standard pen widths use legal tool-specific slider steps', () {
    for (final (pen, expected) in [
      (Pen.ballpointPen(), const [3.0, 8.0, 15.0]),
      (Pen.fountainPen(), const [5.0, 8.0, 15.0]),
      (Pencil(), const [5.0, 8.0, 15.0]),
      (ShapePen(), const [3.0, 6.0, 10.0]),
      (Highlighter(), const [30.0, 40.0, 50.0]),
    ]) {
      expect(pen.sizePresets, expected);
      for (final width in pen.sizePresets!) {
        expect(width, inInclusiveRange(pen.sizeMin, pen.sizeMax));
        expect((width - pen.sizeMin) % pen.sizeStep, 0);
      }
    }
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'wide $platform editor keeps a stroke width from pointer down',
      (tester) async {
        final editor = await mount(
          tester,
          platform: platform,
          editorWidth: 900,
        );
        final pen = editor.currentTool as Pen;
        final color = pen.color;
        final page = editor.coreInfo.pages.first;
        expect(find.byKey(_group), findsOneWidget);
        expect(tester.widget<InkWidthPresets>(find.byKey(_group)).widths, [
          3,
          8,
          15,
        ]);

        void beginStroke() {
          editor.dragPageIndex = 0;
          pen.onDragStart(const Offset(30, 30), page, 0, null);
          pen.onDragUpdate(const Offset(50, 45), null);
        }

        await tester.tap(_preset(0));
        await tester.pump();
        beginStroke();
        final inFlight = Pen.currentStroke!;
        expect(inFlight.options.size, 3);
        await tester.tap(_preset(2));
        await tester.pump();
        expect(editor.currentTool, same(pen));
        expect(pen.color, color);
        expect(Pen.currentStroke, same(inFlight));
        expect(inFlight.options.size, 3);
        expect(
          tester.widget<InkWidthPresets>(find.byKey(_group)).selectedWidth,
          15,
        );
        expect(stows.lastBallpointPenOptions.value.size, 15);
        expect(Pen.ballpointPen().options.size, 15);
        editor.onDrawEnd(ScaleEndDetails());
        beginStroke();
        expect(Pen.currentStroke!.options.size, 15);
        editor.onDrawEnd(ScaleEndDetails());
        expect(page.strokes.map((stroke) => stroke.options.size), [3, 15]);

        final (bytes, _) = editor.coreInfo.saveToBinary(currentPageIndex: 0);
        final reloaded = (await tester.runAsync(
          () => EditorCoreInfo.loadFromFileContents(
            bsonBytes: bytes,
            path: '/width-presets-reloaded',
            onlyFirstPage: false,
          ),
        ))!;
        expect(
          reloaded.pages.first.strokes.map((stroke) => stroke.options.size),
          [3, 15],
        );
        reloaded.dispose();
        editor.cancelAutosaveAndMarkSaved();
      },
    );
  }

  testWidgets('compact editor uses local width and retains exact pen slider', (
    tester,
  ) async {
    final editor = await mount(
      tester,
      platform: TargetPlatform.android,
      editorWidth: 320,
    );
    expect(find.byKey(_group), findsNothing);
    await tester.tap(find.byTooltip(t.editor.pens.ballpointPen));
    await tester.pumpAndSettle();
    final slider = find.byKey(_slider);
    expect(slider, findsOneWidget);
    await _dragToMiddle(tester);
    expect((editor.currentTool as Pen).options.size, 13);
    expect(stows.lastBallpointPenOptions.value.size, 13);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide editor keeps presets and exact slider in sync', (
    tester,
  ) async {
    await mount(tester, platform: TargetPlatform.windows, editorWidth: 900);
    await tester.tap(find.byTooltip(t.editor.pens.ballpointPen));
    await tester.pumpAndSettle();
    await _dragToMiddle(tester);
    expect(
      tester.widget<InkWidthPresets>(find.byKey(_group)).selectedWidth,
      13,
    );
    await tester.tap(_preset(1));
    await tester.pumpAndSettle();
    expect(tester.widget<InkWidthPresets>(find.byKey(_group)).selectedWidth, 8);
    expect(
      find.descendant(of: find.byType(SizePicker), matching: find.text('8')),
      findsOneWidget,
    );
  });
}
