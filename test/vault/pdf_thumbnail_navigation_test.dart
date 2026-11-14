import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/canvas_preview.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/toolbar/editor_page_manager.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import '../office/office_original_preview_test.dart'
    show
        officePreviewDocumentsClosed,
        officePreviewPdfiumAvailable,
        officePreviewRead,
        officePreviewUntil,
        withOfficePreviewPdfium;
import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      '${platform.name} PDF page navigation opens the tapped thumbnail in the viewport',
      (tester) => _withLandscapePdf(tester, platform, (editor, pageIds) async {
        const target = 2;
        expect(editor.currentPageIndex, isNot(target));
        await _tapThumbnail(tester, target);
        _expectVisiblePage(tester, editor, target, pageIds[target]);
      }),
      skip: !officePreviewPdfiumAvailable,
    );

    testWidgets(
      '${platform.name} PDF page navigation restores the uncached saved page in the viewport',
      (tester) => _withLandscapePdf(tester, platform, (editor, pageIds) async {
        _expectVisiblePage(tester, editor, 1, pageIds[1]);
      }, initialPageIndex: 1),
      skip: !officePreviewPdfiumAvailable,
    );

    testWidgets(
      '${platform.name} PDF single page mode retains the selected page and zoom',
      (tester) => _withLandscapePdf(
        tester,
        platform,
        (editor, pageIds) async {
          const target = 2;
          _expectVisiblePage(tester, editor, target, pageIds[target]);
          final canvas = tester.state<CanvasGestureDetectorState>(
            find.byType(CanvasGestureDetector),
          );
          canvas.zoomIn();
          canvas.zoomIn();
          canvas.zoomIn();
          await tester.pumpAndSettle();
          final viewer = find.byType(InteractiveCanvasViewer);
          final transform = tester
              .widget<InteractiveCanvasViewer>(viewer)
              .transformationController!;
          final zoom = transform.value.getMaxScaleOnAxis();
          expect(zoom, greaterThan(1.2));
          transform.value = transform.value.clone()
            ..leftTranslateByDouble(-14, -12, 0, 1);
          await tester.pumpAndSettle();
          final selected = editor.coreInfo.pages[target];
          Offset viewedPoint() =>
              selected.renderBox!.globalToLocal(tester.getCenter(viewer));
          final viewedBefore = viewedPoint();
          final toggle = find.byKey(
            const ValueKey('editor-single-page-toggle'),
          );
          expect(toggle, findsOneWidget);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          _expectVisiblePage(tester, editor, target, pageIds[target]);
          expect(tester.state<EditorState>(find.byType(Editor)), same(editor));
          expect(
            tester
                .widget<InteractiveCanvasViewer>(viewer)
                .transformationController,
            same(transform),
          );
          expect(transform.value.getMaxScaleOnAxis(), closeTo(zoom, .001));
          expect((viewedPoint() - viewedBefore).distance, lessThan(1));
          expect(
            editor.coreInfo.pages
                .where((page) => page.isRendered)
                .map((page) => page.pageId),
            [pageIds[target]],
          );
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          _expectVisiblePage(tester, editor, target, pageIds[target]);
          expect(find.byTooltip('다음 쪽'), findsNothing);
          expect(transform.value.getMaxScaleOnAxis(), closeTo(zoom, .001));
          expect((viewedPoint() - viewedBefore).distance, lessThan(1));
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('다음 쪽'));
          await tester.pumpAndSettle();
          _expectVisiblePage(tester, editor, target + 1, pageIds[target + 1]);
          await tester.tap(find.byTooltip('이전 쪽'));
          await tester.pumpAndSettle();
          _expectVisiblePage(tester, editor, target, pageIds[target]);
          final shortPage = editor.coreInfo.pages[1];
          expect(
            editor.revealPage(
              pageIds[1],
              background: shortPage.backgroundImage,
            ),
            isTrue,
          );
          await tester.pumpAndSettle();
          _expectVisiblePage(tester, editor, 1, pageIds[1]);
          await _tapThumbnail(tester, target);
          _expectVisiblePage(tester, editor, target, pageIds[target]);
          expect(stows.lastSinglePageMode.value, isTrue);
        },
        initialPageIndex: 2,
        mixedPageSizes: true,
      ),
      skip: !officePreviewPdfiumAvailable,
    );
  }

  testWidgets(
    'an exact link centers a very wide first PDF page',
    (tester) => _withLandscapePdf(tester, TargetPlatform.android, (
      editor,
      pageIds,
    ) async {
      final first = editor.coreInfo.pages.first;
      expect(
        editor.revealPage(pageIds.first, background: first.backgroundImage),
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      _expectVisiblePage(tester, editor, 0, pageIds.first);
    }, firstPageFormat: const PdfPageFormat(320, 24)),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'a preferred single page mode restores the saved short PDF page',
    (tester) => _withLandscapePdf(
      tester,
      TargetPlatform.android,
      (editor, pageIds) async {
        _expectVisiblePage(tester, editor, 1, pageIds[1]);
        expect(editor.coreInfo.pages.first.renderBox, isNull);
        expect(find.byTooltip('연속 스크롤'), findsOneWidget);
        expect(find.byTooltip('이전 쪽'), findsOneWidget);
      },
      initialPageIndex: 1,
      mixedPageSizes: true,
      preferSinglePage: true,
    ),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'importing a fresh mixed PDF preserves actual page dimensions and existing IDs',
    (tester) => _withLandscapePdf(tester, TargetPlatform.android, (
      editor,
      pageIds,
    ) async {
      final pages = editor.coreInfo.pages;
      final existing = pages.toList();
      final source = (pages.first.backgroundImage as PdfEditorImage).pdfFile!;
      final copy = await officePreviewRead(
        tester,
        () => source.copy('${source.parent.path}/imported-mixed.pdf'),
      );

      expect(
        await officePreviewRead(
          tester,
          () => editor.importPdfFromFilePath(copy.path),
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
      final firstAdded = existing.length - 1;
      expect(pages.take(firstAdded), orderedEquals(existing.take(firstAdded)));
      expect(pages.last, same(existing.last));
      final added = pages.sublist(firstAdded, pages.length - 1);
      expect(added, hasLength(4));
      final addedIds = added.map((page) => page.pageId).toSet();
      expect(addedIds, hasLength(4));
      expect(addedIds.intersection(pageIds.toSet()), isEmpty);
      for (var index = 0; index < added.length; index++) {
        final background = added[index].backgroundImage as PdfEditorImage;
        expect(background.pdfPage, index);
        expect(background.pdfFile?.path, copy.path);
      }
      expect(added[1].size, const Size(EditorPage.defaultWidth, 281.25));
      expect(added[2].size, const Size(EditorPage.defaultWidth, 1500));
      editor.cancelAutosaveAndMarkSaved();
    }, mixedPageSizes: true),
    skip: !officePreviewPdfiumAvailable,
  );
}

Future<void> _tapThumbnail(WidgetTester tester, int target) async {
  await tester.tap(find.byTooltip(t.editor.pages));
  await tester.pumpAndSettle();
  final manager = find.byType(EditorPageManager);
  final thumbnail = find.descendant(
    of: manager,
    matching: find.byWidgetPredicate(
      (widget) => widget is CanvasPreview && widget.pageIndex == target,
    ),
  );
  expect(manager, findsOneWidget);
  await tester.ensureVisible(thumbnail);
  await tester.tap(thumbnail);
  await tester.pumpAndSettle();
  if (manager.evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
  }
  expect(manager, findsNothing);
}

void _expectVisiblePage(
  WidgetTester tester,
  EditorState editor,
  int expectedIndex,
  String expectedId,
) {
  final center = tester.getCenter(find.byType(InteractiveCanvasViewer));
  final actualAtCenter = editor.onWhichPageIsFocalPoint(center);
  expect(
    actualAtCenter,
    expectedIndex,
    reason: 'Real page under the viewport center',
  );
  final visible = editor.coreInfo.pages[actualAtCenter!];
  expect(visible.pageId, expectedId);
  expect((visible.backgroundImage as PdfEditorImage).pdfPage, expectedIndex);
  expect(editor.currentPageIndex, expectedIndex);
}

Future<void> _withLandscapePdf(
  WidgetTester tester,
  TargetPlatform platform,
  Future<void> Function(EditorState, List<String>) check, {
  int? initialPageIndex,
  PdfPageFormat firstPageFormat = const PdfPageFormat(320, 180),
  bool mixedPageSizes = false,
  bool preferSinglePage = false,
}) => withOfficePreviewPdfium(tester, () async {
  final phone = platform == TargetPlatform.android;
  final size = phone ? const Size(360, 720) : const Size(1440, 900);
  final editorWidth = phone ? 360.0 : 560.0;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final oldPlatform = debugDefaultTargetPlatformOverride;
  final oldSinglePageMode = stows.lastSinglePageMode.value;
  debugDefaultTargetPlatformOverride = platform;
  stows.lastSinglePageMode.value = preferSinglePage;
  final directory = await officePreviewRead(
    tester,
    () => Directory.systemTemp.createTemp('pdf-thumbnail-navigation-'),
  );
  try {
    final path = '${directory.path}/landscape.sbn2';
    expect(CanvasTransformCache.get(path), isNull);
    final core = await officePreviewRead(tester, () async {
      final document = pw.Document();
      final colors = [
        PdfColors.red,
        PdfColors.blue,
        PdfColors.green,
        PdfColors.orange,
      ];
      for (var index = 0; index < colors.length; index++) {
        final format = switch (index) {
          0 => firstPageFormat,
          1 when mixedPageSizes => const PdfPageFormat(320, 90),
          2 when mixedPageSizes => const PdfPageFormat(240, 360),
          _ => const PdfPageFormat(320, 180),
        };
        document.addPage(
          pw.Page(
            pageFormat: format,
            margin: pw.EdgeInsets.zero,
            build: (_) => pw.Container(
              width: format.width,
              height: format.height,
              color: colors[index],
            ),
          ),
        );
      }
      final file = await File('${directory.path}/landscape.pdf')
          .writeAsBytes(await document.save());
      final loaded = EditorCoreInfo(filePath: path)
        ..initialPageIndex = initialPageIndex;
      final native = await loaded.assetCache.pdfDocumentCache.load(file.path);
      await native.loadPagesProgressively<void>(
        onPageLoadProgress: (_, _, _) => true,
      );
      for (var index = 0; index < native.pages.length; index++) {
        final page = native.pages[index];
        expect(page.isLoaded, isTrue);
        expect(page.pageNumber, index + 1);
        final pageSize = Size(
          EditorPage.defaultWidth,
          EditorPage.defaultWidth * page.height / page.width,
        );
        loaded.pages.add(
          EditorPage(
            size: pageSize,
            backgroundImage: PdfEditorImage(
              id: loaded.nextImageId++,
              assetCache: loaded.assetCache,
              pdfBytes: null,
              pdfFile: file,
              pdfPage: index,
              pageIndex: index,
              pageSize: pageSize,
              naturalSize: Size(page.width, page.height),
              onMoveImage: null,
              onDeleteImage: null,
              onMiscChange: null,
            ),
          ),
        );
      }
      if (mixedPageSizes) {
        expect(loaded.pages[1].size.aspectRatio, greaterThan(3));
        expect(loaded.pages[2].size.aspectRatio, lessThan(1));
      }
      loaded.pages.add(EditorPage());
      return loaded;
    });
    expect(
      core.pages.where((page) => page.backgroundImage != null),
      hasLength(4),
    );
    final pageIds = core.pages.map((page) => page.pageId).toList();
    var loaded = false;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: editorWidth,
              height: size.height,
              child: Editor(
                path: path,
                loadSnapshot: () async => core,
                onSaveSnapshot: (_, _) async {},
                onLoaded: (_) => loaded = true,
                showDocumentHeader: false,
              ),
            ),
          ),
        ),
      ),
    );
    final viewer = find.byType(InteractiveCanvasViewer);
    await officePreviewUntil(
      tester,
      () =>
          loaded &&
          viewer.evaluate().length == 1 &&
          core.pages.any((page) => page.renderBox != null),
      'The actual PDF editor and its laid-out pages must be ready',
    );
    await tester.pump();
    expect(tester.getSize(viewer).width, editorWidth);
    final editor = tester.state<EditorState>(find.byType(Editor));
    await check(editor, pageIds);
  } finally {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    await officePreviewDocumentsClosed(tester);
    await tester.runAsync(() => directory.delete(recursive: true));
    stows.lastSinglePageMode.value = oldSinglePageMode;
    debugDefaultTargetPlatformOverride = oldPlatform;
  }
});
