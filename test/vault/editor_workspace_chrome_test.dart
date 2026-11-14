import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/canvas/save_indicator.dart';
import 'package:saber/components/toolbar/toolbar.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  testWidgets(
    'workspace drawing tools use the top layout with a side preference',
    (tester) async {
      final previous = stows.editorToolbarAlignment.value;
      stows.editorToolbarAlignment.value = AxisDirection.left;
      addTearDown(() => stows.editorToolbarAlignment.value = previous);

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Editor(
              path: '/workspace-top',
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final layout = tester.widget<Flex>(
        find
            .descendant(of: find.byType(Toolbar), matching: find.byType(Flex))
            .first,
      );
      expect(layout.direction, Axis.vertical);
      expect(layout.verticalDirection, VerticalDirection.up);
    },
  );

  testWidgets('standalone snapshot editor keeps its own title and back', (
    tester,
  ) async {
    var backs = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Editor(
            path: '/standalone-header',
            customTitle: 'Standalone PDF',
            onSaveSnapshot: (_, _) async {},
            onBack: () => backs++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Standalone PDF'), findsOneWidget);
    expect(find.byType(SaveIndicator), findsOneWidget);
    await tester.tap(find.byTooltip('저장하고 노트 목록으로'));
    expect(backs, 1);
  });

  testWidgets(
    'embedded editor leaves navigation to its parent and keeps page actions',
    (tester) async {
      var backs = 0;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                title: const Text('Workspace note'),
                leading: BackButton(onPressed: () => backs++),
              ),
              body: Editor(
                path: '/workspace-header',
                customTitle: 'Workspace note',
                showDocumentHeader: false,
                onSaveSnapshot: (_, _) async {},
                onBack: () => backs++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Workspace note'), findsOneWidget);
      expect(find.byType(SaveIndicator), findsNothing);
      expect(find.byTooltip(t.editor.pages), findsOneWidget);
      final editor = tester.state<EditorState>(find.byType(Editor));
      final count = editor.coreInfo.pages.length;
      await tester.tap(find.byTooltip(t.editor.menu.insertPage));
      expect(editor.coreInfo.pages.length, count + 1);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      expect(backs, 1);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets('single page handwriting keeps the saved page through a resize', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 780);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final oldMode = stows.lastSinglePageMode.value;
    final oldTool = stows.lastTool.value;
    stows.lastSinglePageMode.value = true;
    stows.lastTool.value = .fountainPen;
    addTearDown(() {
      stows.lastSinglePageMode.value = oldMode;
      stows.lastTool.value = oldTool;
    });

    const path = '/workspace-single-resize';
    const pageIndex = 1;
    final page = EditorPage(size: const Size(720, 980));
    final core = EditorCoreInfo(filePath: path)
      ..initialPageIndex = pageIndex
      ..pages.addAll([EditorPage(), page, EditorPage()]);
    int? savedIndex;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Editor(
            path: path,
            showDocumentHeader: false,
            loadSnapshot: () async => core,
            onSaveSnapshot: (_, index) async {
              savedIndex = index;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final editorFinder = find.byType(Editor);
    final editor = tester.state<EditorState>(editorFinder);
    final canvas = tester.state<CanvasGestureDetectorState>(
      find.byType(CanvasGestureDetector),
    );
    final viewer = find.byType(InteractiveCanvasViewer);
    final transform = tester
        .widget<InteractiveCanvasViewer>(viewer)
        .transformationController!;
    expect(canvas.singlePageMode, isTrue);
    expect(editor.currentPageIndex, pageIndex);
    canvas.zoomIn();
    canvas.zoomIn();
    await tester.pumpAndSettle();
    final zoom = transform.value.getMaxScaleOnAxis();
    expect(zoom, greaterThan(1.1));

    tester.view.physicalSize = const Size(860, 480);
    await tester.pumpAndSettle();
    expect(tester.state<EditorState>(editorFinder), same(editor));
    expect(
      tester.widget<InteractiveCanvasViewer>(viewer).transformationController,
      same(transform),
    );
    expect(transform.value.getMaxScaleOnAxis(), closeTo(zoom, .001));
    expect(editor.currentPageIndex, pageIndex);
    expect(
      core.pages.where((page) => page.isRendered).map((page) => page.pageId),
      [page.pageId],
    );
    final center = tester.getCenter(viewer);
    expect(editor.onWhichPageIsFocalPoint(center), pageIndex);

    final end = center + const Offset(64, 6);
    final stylus = await tester.startGesture(
      center - const Offset(64, 6),
      kind: PointerDeviceKind.stylus,
    );
    await stylus.moveTo(center, timeStamp: const Duration(milliseconds: 20));
    await stylus.moveTo(end, timeStamp: const Duration(milliseconds: 40));
    await stylus.up(timeStamp: const Duration(milliseconds: 50));
    await tester.pump();

    expect(core.pages.expand((page) => page.strokes), hasLength(1));
    final point = page.strokes.single.points.last;
    final renderedEnd = page.renderBox!.localToGlobal(Offset(point.x, point.y));
    expect((renderedEnd - end).distance, lessThan(2));
    await editor.saveToFile();
    expect(savedIndex, pageIndex);
  });
}
