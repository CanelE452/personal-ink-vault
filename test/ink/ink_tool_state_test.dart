import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/ink_engine.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The ink windows' contract (Task 2): the tool state the floating bar and
/// the pen panel read, the editor's host that changes it, and the engine
/// values the quick note will use.
void main() {
  FlavorConfig.setup();

  test('update notifies once per change and not when nothing changed', () {
    final pen = Pen.fountainPen()
      ..color = const Color(0xff112233)
      ..options = Pen.fountainPen().options.copyWith(size: 7, streamline: .4);
    final state = InkToolState(pen);
    addTearDown(state.dispose);
    var heard = 0;
    state.addListener(() => heard++);
    // the pen's values to start with
    expect(state.tool, same(pen));
    expect(
      (state.color, state.size, state.stabiliser, state.eyedropper),
      (const Color(0xff112233), 7.0, .4, false),
    );

    state.update();
    state.update(color: const Color(0xff112233), size: 7, stabiliser: .4);
    state.update(tool: pen, eyedropper: false);
    expect(heard, 0, reason: 'nothing changed');

    state.update(color: const Color(0xff445566));
    expect((heard, state.color), (1, const Color(0xff445566)));
    // several values at once: one notice
    state.update(size: 9, stabiliser: .2, eyedropper: true);
    expect(heard, 2);
    expect((state.size, state.stabiliser, state.eyedropper), (9.0, .2, true));
    state.update(size: 9, eyedropper: true);
    expect(heard, 2, reason: 'the same values again');

    // a tool that is not a pen keeps the last pen's values
    final eraser = Eraser();
    state.update(tool: eraser);
    expect(heard, 3);
    expect(state.tool, same(eraser));
    expect(
      (state.color, state.size, state.stabiliser),
      (const Color(0xff445566), 9.0, .2),
    );
    state.update(tool: eraser);
    expect(heard, 3);

    // a pen brings its own values (the pens stay the source)
    final other = Pen.ballpointPen()
      ..color = const Color(0xff778899)
      ..options = Pen.ballpointPen().options.copyWith(size: 3, streamline: 0);
    state.update(tool: other);
    expect(heard, 4);
    expect(state.tool, same(other));
    expect(
      (state.color, state.size, state.stabiliser),
      (const Color(0xff778899), 3.0, 0.0),
    );
    // the pen in hand changed: reading it again tells the change
    other.color = const Color(0xffaabbcc);
    state.update(tool: other);
    expect((heard, state.color), (5, const Color(0xffaabbcc)));
  });

  test('quickNote has the editor pens, the stroke eraser and no lasso', () {
    const quickNote = InkEngineSupport.quickNote;
    expect(quickNote.pens, isNull);
    expect(quickNote.penKinds, InkEngineSupport.editor.penKinds);
    final state = InkToolState(Pen.fountainPen());
    addTearDown(state.dispose);
    expect(
      quickNote.toolFor(KitPenKind.fountain, state).toolId,
      ToolId.fountainPen,
    );
    expect(quickNote.toolFor(KitPenKind.brush, state).toolId, ToolId.brush);
    expect(quickNote.penSettings, isTrue);
    expect(quickNote.eraserModes, [EraserMode.stroke]);
    expect(quickNote.eraserModeOf(EraserMode.lasso), EraserMode.stroke);
    expect(quickNote.eraserTargets, isNull);
    expect(quickNote.lassoTargets, isEmpty);
  });

  test('keepTargetsOn leaves an engine without lasso targets alone', () {
    final lasso = [
      stows.selectInk,
      stows.selectHighlighter,
      stows.selectShapes,
      stows.selectImages,
    ];
    final saved = [for (final s in lasso) s.value];
    addTearDown(() {
      for (final (i, s) in lasso.indexed) {
        s.value = saved[i];
      }
    });
    for (final s in lasso) {
      s.value = false;
    }
    InkEngineSupport.quickNote.keepTargetsOn();
    expect([for (final s in lasso) s.value], [false, false, false, false]);
  });

  group('the editor as host', () {
    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      setupMockPathProvider();
      setupMockPrinting();
      setupMockWindowManager();
      await FileManager.init();
      final saved = (
        stows.lastTool.value,
        stows.lastPenFamily.value,
        stows.lastFountainPenOptions.value,
        stows.lastFountainPenColor.value,
        stows.recentColorsPositioned.value,
        stows.recentColorsChronological.value,
      );
      stows.lastTool.value = ToolId.fountainPen;
      stows.lastPenFamily.value = ToolId.fountainPen;
      stows.editorGestureMode.value = false;
      addTearDown(() {
        stows.lastTool.value = saved.$1;
        stows.lastPenFamily.value = saved.$2;
        stows.lastFountainPenOptions.value = saved.$3;
        stows.lastFountainPenColor.value = saved.$4;
        stows.recentColorsPositioned.value = saved.$5;
        stows.recentColorsChronological.value = saved.$6;
        Pen.currentPen = Pen.fountainPen();
      });
    });

    testWidgets('selecting a tool through the host updates the state', (
      tester,
    ) async {
      const size = Size(1000, 1400);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: size),
          child: TranslationProvider(
            child: MaterialApp(
              localizationsDelegates: const [
                FlutterQuillLocalizations.delegate,
              ],
              home: Editor(
                path: '/ink-tool-host',
                onSaveSnapshot: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editor = tester.state<EditorState>(find.byType(Editor));
      // the host the editor hands the floating bar
      final host = tester
          .widget<KitFloatingBar>(find.byType(KitFloatingBar))
          .host;
      final pen = editor.currentTool;
      expect(pen, isA<Pen>());
      expect(host.toolState.tool, same(pen));
      var heard = 0;
      void count() => heard++;
      host.toolState.addListener(count);
      addTearDown(() => host.toolState.removeListener(count));

      host.selectTool(Eraser());
      expect(editor.currentTool, isA<Eraser>());
      expect(host.toolState.tool, same(editor.currentTool));
      expect(heard, 1);
      // the eraser again puts the tool before it back
      host.selectTool(Eraser());
      expect(editor.currentTool, same(pen));
      expect(host.toolState.tool, same(pen));
      expect(heard, 2);
      await tester.pumpAndSettle();

      // the tool set another way (a picture put in takes the lasso) is
      // the state's too
      editor.currentTool = Select.currentSelect;
      expect(host.toolState.tool, same(Select.currentSelect));
      expect(heard, 3);
      editor.currentTool = pen;
      await tester.pumpAndSettle();

      // size and stabiliser go to the pen in hand, then to the state
      final level = (pen as Pen).options.size == 9 ? 11.0 : 9.0;
      host.setSize(level);
      expect((pen.options.size, host.toolState.size), (level, level));
      host.setStabiliser(.3);
      expect((pen.options.streamline, host.toolState.stabiliser), (.3, .3));
      host.setColor(const Color(0xff2f9bf0));
      expect(
        (pen.color, host.toolState.color),
        (const Color(0xff2f9bf0), const Color(0xff2f9bf0)),
      );
      await tester.pumpAndSettle();
    });
  });
}
