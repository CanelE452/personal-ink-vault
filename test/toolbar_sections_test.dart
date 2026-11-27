import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import 'utils/test_mock_channel_handlers.dart';

/// The editor's bars since Task 13B-1: the toolbar (9th draft c) holds the
/// tools, the floating bar under it undo, redo and the tool's values.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  Future<void> mountEditor(
    WidgetTester tester, {
    Size size = const Size(1200, 2000),
  }) async {
    final previousTool = stows.lastTool.value;
    final previousLayout = stows.pageToolbarLayout.value;
    final previousEraserSize = stows.eraserSize.value;
    final previousEraserMode = stows.eraserMode.value;
    final previousRectangle = stows.selectRectangle.value;
    stows.lastTool.value = ToolId.fountainPen;
    stows.pageToolbarLayout.value = const [];
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.lastTool.value = previousTool;
      stows.pageToolbarLayout.value = previousLayout;
      stows.eraserSize.value = previousEraserSize;
      stows.eraserMode.value = previousEraserMode;
      stows.selectRectangle.value = previousRectangle;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: TranslationProvider(
          child: MaterialApp(
            home: Editor(
              path: '/toolbar-sections',
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder tool(String id) => find.byKey(ValueKey('editor-tool-$id'));
  Finder key(String k) => find.byKey(ValueKey(k));
  final bar = key('kit-floating-bar');

  testWidgets(
    "the toolbar: three groups; the pen's values in the floating bar",
    (tester) async {
      await mountEditor(tester);
      double x(Finder f) => tester.getCenter(f).dx;
      // start · middle · end (9th draft c)
      expect(x(key('editor-page-list')), lessThan(x(key('editor-mode'))));
      expect(
        x(key('editor-tools-more')),
        lessThan(x(key('editor-insert-page'))),
      );
      expect(x(key('editor-fullscreen')), lessThan(x(key('editor-doc-menu'))));
      // undo, redo and the pen's width live in the floating bar
      for (final k in const [
        'floating-bar-undo',
        'floating-bar-redo',
        'toolbar-quick-ink-widths',
        'floating-bar-custom-colour',
      ]) {
        expect(
          find.descendant(of: bar, matching: key(k)),
          findsOneWidget,
          reason: k,
        );
      }
    },
  );

  testWidgets('the eraser shows its choices in the floating bar', (
    tester,
  ) async {
    await mountEditor(tester);
    await tester.tap(tool('eraser'));
    await tester.pumpAndSettle();
    // the 10th draft: the kind chip, 「고급 설정」 and three sizes
    expect(
      find.descendant(of: bar, matching: key('floating-bar-eraser-size-40')),
      findsOneWidget,
    );
    expect(key('floating-bar-custom-colour'), findsNothing);
    await tester.tap(key('floating-bar-eraser-kind'));
    await tester.pumpAndSettle();
    await tester.tap(key('eraser-kind-lasso'));
    await tester.pumpAndSettle();
    expect(stows.eraserMode.value, EraserMode.lasso);
  });

  testWidgets('the lasso has no floating bar', (tester) async {
    await mountEditor(tester);
    await tester.tap(tool('lasso'));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
  });

  testWidgets('docked left, the floating bar stands upright without overflow', (
    tester,
  ) async {
    final place = stows.floatingBarPosition.value;
    stows.floatingBarPosition.value = 'left';
    addTearDown(() => stows.floatingBarPosition.value = place);
    await mountEditor(tester, size: const Size(800, 900));
    expect(tester.takeException(), isNull);
    expect(tester.widget<Flex>(bar).direction, Axis.vertical);
  });

  testWidgets('the toolbar has no pencil, highlighter or export button', (
    tester,
  ) async {
    await mountEditor(tester);
    for (final tooltip in const ['연필', '형광펜', '내보내기', '손가락 필기']) {
      expect(
        find.descendant(
          of: find.byType(KitEditorToolbar),
          matching: find.byTooltip(tooltip),
        ),
        findsNothing,
        reason: tooltip,
      );
    }
  });
}
