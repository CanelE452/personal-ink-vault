import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// 스포이트 (user decision 2026-11-19): the next tap on a page gives the pen
/// the colour of the page's picture there, and draws nothing.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  /// A fountain pen in hand; the colours the eyedropper writes are restored.
  Future<EditorState> mountEditor(
    WidgetTester tester, {
    ThemeData? theme,
  }) async {
    final lastTool = stows.lastTool.value;
    final penColor = stows.lastFountainPenColor.value;
    final recent = List.of(stows.recentColorsChronological.value);
    final placed = List.of(stows.recentColorsPositioned.value);
    stows.lastTool.value = ToolId.fountainPen;
    addTearDown(() {
      stows.lastTool.value = lastTool;
      stows.lastFountainPenColor.value = penColor;
      stows.recentColorsChronological.value = recent;
      stows.recentColorsPositioned.value = placed;
    });
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: theme,
          home: Editor(
            path: '/editor-eyedropper',
            onSaveSnapshot: (_, _) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  AppActionRegistry actionsOf(WidgetTester tester) =>
      tester.widget<AppActionScope>(find.byType(AppActionScope)).notifier!;

  /// A line 40 wide across y 300 of the first page, in [color].
  Future<void> drawLine(
    WidgetTester tester,
    EditorState editor,
    Color color,
  ) async {
    final page = editor.coreInfo.pages.first;
    page.insertStroke(
      Stroke(
        color: color,
        pressureEnabled: false,
        options: StrokeOptions(size: 40),
        pageIndex: 0,
        page: page,
        toolId: ToolId.ballpointPen,
      )..addPoints([for (var x = 100.0; x <= 500; x += 20) Offset(x, 300)]),
    );
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pump();
  }

  /// Taps the first page at (300, 300) and waits for the reading there.
  Future<void> pickAtLine(WidgetTester tester, EditorState editor) async {
    final page = editor.coreInfo.pages.first;
    // Reading the page's picture is real work: wait for it outside fake time.
    await tester.runAsync(() async {
      await tester.tapAt(page.renderBox!.localToGlobal(const Offset(300, 300)));
      await editor.eyedropperPick;
    });
    await tester.pump();
  }

  testWidgets('eyedropper picks the colour under the next tap and draws nothing', (
    tester,
  ) async {
    const known = Color(0xFF1E88E5);
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    final pen = editor.currentTool as Pen;
    pen.color = Colors.black;
    await drawLine(tester, editor, known);

    final actions = actionsOf(tester);
    expect(
      actions.run(AppActionIds.eyedropper, tester.element(find.byType(Editor))),
      isTrue,
    );
    await tester.pump();
    expect(actions.lookup(AppActionIds.eyedropper)!.checked, isTrue);
    // A pen drag while it waits draws nothing either, and is not its tap.
    final from = page.renderBox!.localToGlobal(const Offset(150, 520));
    final drag = await tester.startGesture(
      from,
      kind: PointerDeviceKind.stylus,
    );
    await drag.moveTo(from + const Offset(150, 10));
    await drag.moveTo(from + const Offset(300, 20));
    await drag.up();
    await tester.pump();
    expect(page.strokes, hasLength(1));
    expect(actions.lookup(AppActionIds.eyedropper)!.checked, isTrue);
    await pickAtLine(tester, editor);
    expect(editor.currentTool, same(pen));
    expect(pen.color.toARGB32(), known.toARGB32());
    expect(page.strokes, hasLength(1), reason: 'the picking tap drew nothing');
    expect(actions.lookup(AppActionIds.eyedropper)!.checked, isFalse);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('on an inverted page the eyedropper gives the ink colour back', (
    tester,
  ) async {
    final autoInvert = stows.editorAutoInvert.value;
    stows.editorAutoInvert.value = true;
    addTearDown(() => stows.editorAutoInvert.value = autoInvert);
    // Dark, so the page shows it far lighter (inverting keeps hue, flips lightness).
    const known = Color(0xFF0D47A1);
    final editor = await mountEditor(tester, theme: ThemeData.dark());
    final pen = editor.currentTool as Pen;
    pen.color = Colors.black;
    await drawLine(tester, editor, known);
    actionsOf(
      tester,
    ).run(AppActionIds.eyedropper, tester.element(find.byType(Editor)));
    await tester.pump();
    await pickAtLine(tester, editor);
    // The page shows the line inverted; the pen gets the line's own colour
    // (8 bits a channel each way).
    int channel(double value) => (value * 255).round();
    for (final (got, want) in [
      (pen.color.r, known.r),
      (pen.color.g, known.g),
      (pen.color.b, known.b),
    ]) {
      expect(channel(got), closeTo(channel(want), 1));
    }
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('eyedropper stops on Esc and on a second press', (tester) async {
    final editor = await mountEditor(tester);
    final actions = actionsOf(tester);
    final context = tester.element(find.byType(Editor));
    bool? waiting() => actions.lookup(AppActionIds.eyedropper)!.checked;

    actions.run(AppActionIds.eyedropper, context);
    await tester.pump();
    expect(waiting(), isTrue);
    actions.run(AppActionIds.eyedropper, context);
    await tester.pump();
    expect(waiting(), isFalse);

    actions.run(AppActionIds.eyedropper, context);
    await tester.pump();
    expect(waiting(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(waiting(), isFalse);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('turning read-only on stops the eyedropper', (tester) async {
    final editor = await mountEditor(tester);
    final actions = actionsOf(tester);
    final context = tester.element(find.byType(Editor));
    actions.run(AppActionIds.eyedropper, context);
    await tester.pump();
    expect(actions.lookup(AppActionIds.eyedropper)!.checked, isTrue);
    actions.run(AppActionIds.readOnly, context);
    await tester.pump();
    expect(editor.inkLocked.value, isTrue);
    expect(actions.lookup(AppActionIds.eyedropper)!.checked, isFalse);
    // the mode pill's own timers
    await tester.pumpAndSettle(const Duration(seconds: 3));
    editor.cancelAutosaveAndMarkSaved();
  });
}
