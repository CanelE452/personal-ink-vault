import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The new pens in the editor: the floating bar and the pen panel take them
/// through the editor, which keeps each one apart from the old pens.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
    final saved = (
      stows.lastTool.value,
      stows.lastPenFamily.value,
      stows.editorToolbarTools.value,
      stows.pageToolbarLayout.value,
      stows.floatingBarPosition.value,
    );
    stows.lastTool.value = ToolId.fountainPen;
    stows.lastPenFamily.value = ToolId.fountainPen;
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.floatingBarPosition.value = 'top';
    stows.editorGestureMode.value = false;
    addTearDown(() {
      stows.lastTool.value = saved.$1;
      stows.lastPenFamily.value = saved.$2;
      stows.editorToolbarTools.value = saved.$3;
      stows.pageToolbarLayout.value = saved.$4;
      stows.floatingBarPosition.value = saved.$5;
      for (final stow in [
        stows.highlighterOpacity,
        stows.roundHighlighterOpacity,
        stows.lastRoundHighlighterColor,
        stows.lastRoundHighlighterOptions,
      ]) {
        stow.value = stow.defaultValue;
      }
      stows.lastHighlighterKind.value = stows.lastHighlighterKind.defaultValue;
      Pen.currentPen = Pen.fountainPen();
      Highlighter.currentHighlighter = Highlighter();
    });
  });

  Finder key(String k) => find.byKey(ValueKey(k));

  Future<EditorState> mountEditor(WidgetTester tester) async {
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
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(
              path: '/editor-new-pens',
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  testWidgets('the editor keeps the brush and the round highlighter apart '
      'from the old pens', (tester) async {
    final editor = await mountEditor(tester);
    await tester.tap(key('floating-bar-pen-brush'));
    await tester.pumpAndSettle();
    final brush = editor.currentTool;
    expect(brush.toolId, ToolId.brush);

    // the flat highlighter from the bar, then the round one from its panel
    await tester.tap(key('floating-bar-pen-hlchisel'));
    await tester.pumpAndSettle();
    final flat = editor.currentTool;
    expect(penKindOf(flat), KitPenKind.highlighterChisel);
    await tester.tap(key('floating-bar-pen-hlchisel'));
    await tester.pumpAndSettle();
    expect(find.byType(KitPenPanel), findsOneWidget);
    await tester.tap(
      key('pen-panel-pen-${KitPenKind.highlighterRound.previewId}'),
    );
    await tester.pumpAndSettle();
    expect(penKindOf(editor.currentTool), KitPenKind.highlighterRound);
    // the 형광펜 action and the bar still give the flat one
    expect(identical(Highlighter.currentHighlighter, flat), isTrue);

    // its opacity is its own
    await tester.tap(
      find.descendant(
        of: key('pen-panel-opacity'),
        matching: find.byWidgetPredicate(
          (w) => w is KitIcon && w.name == KitIconName.minus,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(stows.roundHighlighterOpacity.value, 90);
    expect(stows.highlighterOpacity.value, Highlighter.alpha);
    expect(editor.currentTool.toolId, ToolId.highlighter);

    // back to the flat one, and the brush comes back as it was
    await tester.tap(
      key('pen-panel-pen-${KitPenKind.highlighterChisel.previewId}'),
    );
    await tester.pumpAndSettle();
    expect(identical(editor.currentTool, flat), isTrue);
    await tester.tap(key('pen-panel-close'));
    await tester.pumpAndSettle();
    await tester.tap(key('floating-bar-pen-brush'));
    await tester.pumpAndSettle();
    expect(identical(editor.currentTool, brush), isTrue);
    editor.cancelAutosaveAndMarkSaved();
  });

  // A note closed with a highlighter in hand opens with the same one: the
  // round one keeps an older app able to open the note (v19), so it must not
  // come back as the flat one, whose strokes make the note v21.
  for (final (kind, version) in [
    (KitPenKind.highlighterRound, 19),
    (KitPenKind.highlighterChisel, 21),
  ]) {
    testWidgets('a note closed with ${kind.label} in hand opens with it, and '
        'its stroke keeps the note v$version', (tester) async {
      var editor = await mountEditor(tester);
      await tester.tap(key('floating-bar-pen-hlchisel'));
      await tester.pumpAndSettle();
      await tester.tap(key('floating-bar-pen-hlchisel'));
      await tester.pumpAndSettle();
      await tester.tap(key('pen-panel-pen-${kind.previewId}'));
      await tester.pumpAndSettle();
      expect(penKindOf(editor.currentTool), kind);
      editor.cancelAutosaveAndMarkSaved();

      // closed, then opened again
      await tester.pumpWidget(const SizedBox());
      editor = await mountEditor(tester);
      expect(penKindOf(editor.currentTool), kind);
      expect(stows.lastTool.value, ToolId.highlighter);

      final page = editor.coreInfo.pages.first;
      final from = page.renderBox!.localToGlobal(const Offset(150, 520));
      final pen = await tester.startGesture(
        from,
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveTo(from + const Offset(150, 10));
      await pen.moveTo(from + const Offset(300, 20));
      await pen.up();
      await tester.pump();
      final stroke = page.strokes.single;
      expect(kindOfStroke(stroke.toolId, stroke.style), kind);
      expect(editor.coreInfo.versionToWrite(), version);
      editor.cancelAutosaveAndMarkSaved();
    });
  }
}
