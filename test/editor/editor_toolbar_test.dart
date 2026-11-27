import 'package:collapsible/collapsible.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/read_only_reason.dart';
import 'package:sbn/tool_id.dart';

import '../utils/paint_counts.dart';
import '../utils/test_mock_channel_handlers.dart';

/// The editor with its new toolbar (Task 13B-1, preview 9th draft c).
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
      stows.editorToolbarShowInFullscreen.value,
    );
    stows.lastTool.value = ToolId.fountainPen;
    stows.lastPenFamily.value = ToolId.fountainPen;
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    addTearDown(() {
      stows.lastTool.value = saved.$1;
      stows.lastPenFamily.value = saved.$2;
      stows.editorToolbarTools.value = saved.$3;
      stows.pageToolbarLayout.value = saved.$4;
      stows.editorToolbarShowInFullscreen.value = saved.$5;
      stows.editorGestureMode.value = false;
    });
  });

  Future<EditorState> mountEditor(
    WidgetTester tester, {
    Size size = const Size(1000, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(
              path: '/editor-toolbar',
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  Finder tool(String id) => find.byKey(ValueKey('editor-tool-$id'));
  final bar = find.byKey(const ValueKey('kit-floating-bar'));

  int strokes(EditorState editor) =>
      editor.coreInfo.pages.expand((page) => page.strokes).length;

  Future<void> drawStroke(WidgetTester tester, EditorState editor) async {
    final page = editor.coreInfo.pages.first;
    final box = page.renderBox!;
    final center = Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(page.size.bottomRight(Offset.zero)),
    ).intersect(tester.getRect(find.byType(InteractiveCanvasViewer))).center;
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(center - const Offset(30, 5));
    await pen.moveTo(center);
    await pen.moveTo(center + const Offset(30, 5));
    await pen.up();
    await tester.pump();
  }

  testWidgets('the new toolbar replaces the old one', (tester) async {
    await mountEditor(tester);
    expect(find.byType(KitEditorToolbar), findsOneWidget);
    expect(
      find.byKey(const ValueKey('toolbar-dock-handle')),
      findsNothing,
      reason: 'the toolbar no longer moves',
    );
    expect(find.byKey(const ValueKey('toolbar-tools-scroll')), findsNothing);
    // one width button, the floating bar's
    expect(
      find.byKey(const ValueKey('toolbar-quick-ink-widths')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('gesture mode leaves no stroke; a tool button writes again', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byKey(const ValueKey('editor-mode')));
    await tester.pumpAndSettle();
    expect(stows.editorGestureMode.value, isTrue);
    expect(bar, findsNothing, reason: 'no floating bar in gesture mode');
    await drawStroke(tester, editor);
    expect(strokes(editor), 0);

    await tester.tap(tool('pen'));
    await tester.pumpAndSettle();
    expect(stows.editorGestureMode.value, isFalse);
    expect(bar, findsOneWidget);
    await drawStroke(tester, editor);
    expect(strokes(editor), 1);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the floating bar: pen and eraser show it, again hides it', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    expect(bar, findsOneWidget, reason: 'the editor opens with the pen');
    await tester.tap(tool('pen'));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(editor.currentTool, isA<Pen>(), reason: 'the pen stays in hand');
    await tester.tap(tool('pen'));
    await tester.pumpAndSettle();
    expect(bar, findsOneWidget);

    await tester.tap(tool('lasso'));
    await tester.pumpAndSettle();
    expect(bar, findsNothing, reason: 'another tool, no bar');

    await tester.tap(tool('eraser'));
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Eraser>());
    expect(bar, findsOneWidget);
    await tester.tap(tool('eraser'));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(editor.currentTool, isA<Eraser>(), reason: 'still the eraser');

    await tester.tap(tool('shapes'));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
  });

  testWidgets('pen button brings back the last ink tool', (tester) async {
    final editor = await mountEditor(tester);
    final actions = tester
        .widget<AppActionScope>(find.byType(AppActionScope))
        .notifier!;
    actions.run(
      AppActionIds.toolHighlighter,
      tester.element(find.byType(Editor)),
    );
    await tester.pump();
    await tester.tap(tool('eraser'));
    await tester.pumpAndSettle();
    await tester.tap(tool('pen'));
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Highlighter>());

    actions.run(AppActionIds.toolPen, tester.element(find.byType(Editor)));
    await tester.pump();
    // the highlighter was in hand; take the fine-nib pen from the bar
    await tester.tap(find.byKey(const ValueKey('floating-bar-pen-fountain')));
    await tester.pumpAndSettle();
    final pen = editor.currentTool;
    await tester.tap(tool('shapes'));
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<ShapePen>());
    await tester.tap(tool('pen'));
    await tester.pumpAndSettle();
    expect(editor.currentTool, same(pen), reason: 'not the shape pen');
  });

  testWidgets('toolbar folds when read only or in full screen without it', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    bool folded() => tester
        .widget<Collapsible>(
          find
              .ancestor(
                of: find.byType(KitEditorToolbar),
                matching: find.byType(Collapsible),
              )
              .first,
        )
        .collapsed;
    expect(folded(), isFalse);

    stows.editorToolbarShowInFullscreen.value = true;
    DynamicMaterialApp.setFullscreen(true, updateSystem: false);
    await tester.pumpAndSettle();
    expect(folded(), isFalse, reason: 'shown in full screen');
    stows.editorToolbarShowInFullscreen.value = false;
    DynamicMaterialApp.setFullscreen(false, updateSystem: false);
    DynamicMaterialApp.setFullscreen(true, updateSystem: false);
    await tester.pumpAndSettle();
    expect(folded(), isTrue);
    DynamicMaterialApp.setFullscreen(false, updateSystem: false);
    await tester.pumpAndSettle();
    expect(folded(), isFalse);

    editor.coreInfo.readOnlyReason = ReadOnlyReason.versionTooNew;
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    expect(folded(), isTrue);
    expect(bar, findsNothing);
  });

  testWidgets('quick windows do not repaint the page', (tester) async {
    final editor = await mountEditor(tester);
    final page =
        editor.coreInfo.pages.first.innerCanvasKey.currentContext!
                .findRenderObject()!
            as RenderRepaintBoundary;
    // The page itself is never painted again. Its parent is: a window is a
    // route, and opening one rebuilds the text boxes on the page (they
    // follow the route and the focus), which lays out the canvas's
    // LayoutBuilders above the page; the page's layer is then put back as
    // it was, not painted.
    final before = paintCounts(page);
    final outside = tester.getBottomLeft(find.byType(Editor)) + const Offset(5, -5);

    for (final (button, shows) in [
      ('editor-tools-more', find.text('막대에 없는 도구')),
      ('editor-doc-menu', find.text('쪽 배치')),
      ('floating-bar-pen-fountain', find.byType(KitPenPanel)),
      ('toolbar-quick-ink-widths', find.byKey(const ValueKey('floating-bar-widths'))),
      ('floating-bar-custom-colour', find.byKey(const ValueKey('floating-bar-colours'))),
    ]) {
      await tester.tap(find.byKey(ValueKey(button)));
      await tester.pumpAndSettle();
      expect(shows, findsWidgets, reason: button);
      await tester.tapAt(outside);
      await tester.pumpAndSettle();
      expect(shows, findsNothing, reason: button);
    }
    // an editor without a vault has no quick note (its window is
    // quick_note_window_test's)
    expect(find.byKey(const ValueKey('editor-note-sheet')), findsNothing);
    expectNotPainted(page, before);
    expect(strokes(editor), 0);
  });

  testWidgets('the eraser and lasso windows do not repaint the page', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final page =
        editor.coreInfo.pages.first.innerCanvasKey.currentContext!
                .findRenderObject()!
            as RenderRepaintBoundary;
    final outside =
        tester.getBottomLeft(find.byType(Editor)) + const Offset(5, -5);
    Future<void> openClose(String button, Finder shows) async {
      await tester.tap(find.byKey(ValueKey(button)));
      await tester.pumpAndSettle();
      expect(shows, findsOneWidget, reason: button);
      await tester.tapAt(outside);
      await tester.pumpAndSettle();
      expect(shows, findsNothing, reason: button);
    }

    await tester.tap(tool('eraser'));
    await tester.pumpAndSettle();
    var before = paintCounts(page);
    await openClose(
      'floating-bar-eraser-kind',
      find.byKey(const ValueKey('kit-eraser-type-panel')),
    );
    await openClose(
      'floating-bar-eraser-advanced',
      find.byKey(const ValueKey('kit-eraser-advanced-panel')),
    );
    expectNotPainted(page, before);
    // the lasso: the first press takes it, the second opens its window
    await tester.tap(tool('lasso'));
    await tester.pumpAndSettle();
    before = paintCounts(page);
    await openClose(
      'editor-tool-lasso',
      find.byKey(const ValueKey('kit-lasso-panel')),
    );
    expectNotPainted(page, before);
    expect(strokes(editor), 0);
  });

  testWidgets('「도구 막대 사용자화」 from ⌄ changes the bar', (tester) async {
    await mountEditor(tester);
    await tester.tap(find.byKey(const ValueKey('editor-tools-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('도구 막대 사용자화'));
    await tester.pumpAndSettle();
    expect(find.text('6 / 6'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('펜 막대에 보이기'));
    await tester.pumpAndSettle();
    expect(tool('pen'), findsNothing);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(find.text('6 / 6'), findsNothing);
    expect(find.text('5 / 6'), findsNothing);
  });

  testWidgets('문서 정보 shows the name and the pages', (tester) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    expect(find.text('이름 바꾸기'), findsNothing, reason: 'no host to rename');
    await tester.tap(find.text('문서 정보'));
    await tester.pumpAndSettle();
    expect(find.text(editor.coreInfo.fileName), findsWidgets);
    expect(find.text('${editor.coreInfo.pages.length}쪽'), findsOneWidget);
    expect(find.text('마지막 편집'), findsOneWidget);
  });

  testWidgets('at phone width the bars do not overflow', (tester) async {
    // the pen's floating bar (474) slides along a 360 page
    await mountEditor(tester, size: const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byKey(const ValueKey('editor-doc-menu'))).right,
      lessThanOrEqualTo(360),
    );
  });
}
