import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_controls.dart';
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

/// The floating bar's width button and the window it opens (Task 12): the
/// pen's three widths, named with the pen panel's numbers.
const _group = ValueKey('toolbar-quick-ink-widths');
const _window = ValueKey('floating-bar-widths');

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
    stows.lastTool.value = .ballpointPen;
    stows.lastBallpointPenOptions.value = Pen.ballpointPenOptions;
    Pen.currentPen = Pen.ballpointPen();
    tester.view.physicalSize = const Size(1120, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.lastTool.value = priorTool;
      stows.lastBallpointPenOptions.value = priorOptions;
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
      // StarNote's highlighter widths (starnote-editor-rea.md 3.7), slider step 5.
      (Highlighter(), const [25.0, 35.0, 50.0]),
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
        // one width button: the floating bar's
        expect(find.byKey(_group), findsOneWidget);
        await tester.tap(find.byKey(_group));
        await tester.pumpAndSettle();
        expect(_levels(tester), [
          for (final w in const [3.0, 8.0, 15.0])
            '${sizeToLevel(w, min: pen.sizeMin, max: pen.sizeMax)}',
        ]);

        void beginStroke() {
          editor.dragPageIndex = 0;
          pen.onDragStart(const Offset(30, 30), page, 0, null);
          pen.onDragUpdate(const Offset(50, 45), null);
        }

        await _pick(tester, pen, 3);
        beginStroke();
        final inFlight = Pen.currentStroke!;
        expect(inFlight.options.size, 3);
        await _pick(tester, pen, 15);
        expect(editor.currentTool, same(pen));
        expect(pen.color, color);
        expect(Pen.currentStroke, same(inFlight));
        expect(inFlight.options.size, 3);
        expect(pen.options.size, 15);
        expect(stows.lastBallpointPenOptions.value.size, 15);
        expect(Pen.ballpointPen().options.size, 15);
        editor.inkInput.onDrawEnd(ScaleEndDetails());
        beginStroke();
        expect(Pen.currentStroke!.options.size, 15);
        editor.inkInput.onDrawEnd(ScaleEndDetails());
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

  testWidgets('the width window marks the width in hand', (tester) async {
    final editor = await mount(
      tester,
      platform: TargetPlatform.windows,
      editorWidth: 900,
    );
    final pen = editor.currentTool as Pen;
    await _pick(tester, pen, 8);
    await tester.tap(find.byKey(_group));
    await tester.pumpAndSettle();
    final eight = '${sizeToLevel(8, min: pen.sizeMin, max: pen.sizeMax)}';
    expect(
      tester
          .getSemantics(
            find.descendant(
              of: find.byKey(_window),
              matching: find.bySemanticsLabel(eight),
            ),
          )
          .flagsCollection
          .isSelected
          .toBoolOrNull(),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    editor.cancelAutosaveAndMarkSaved();
  });
}

/// The open width window's choices (their numbers).
List<String> _levels(WidgetTester tester) {
  final segment = tester.widget<KitSegment<double?>>(find.byKey(_window));
  return [for (final (_, label) in segment.options) label];
}

/// Opens the floating bar's width window and picks [width].
Future<void> _pick(WidgetTester tester, Pen pen, double width) async {
  if (find.byKey(_window).evaluate().isEmpty) {
    await tester.tap(find.byKey(_group));
    await tester.pumpAndSettle();
  }
  final level = '${sizeToLevel(width, min: pen.sizeMin, max: pen.sizeMax)}';
  await tester.tap(
    find.descendant(of: find.byKey(_window), matching: find.text(level)),
  );
  await tester.pumpAndSettle();
}
