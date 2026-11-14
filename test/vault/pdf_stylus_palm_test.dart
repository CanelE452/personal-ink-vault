import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import '../office/office_original_preview_test.dart'
    show
        officePreviewDocumentsClosed,
        officePreviewPdf,
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

  for (final cancelPalm in [false, true]) {
    testWidgets(
      'PDF stylus palm ${cancelPalm ? 'cancel' : 'up'} leaves one complete pen stroke',
      (tester) => _withPdfEditor(tester, (editor, center, transform) async {
        final before = transform.value.storage.toList();
        final pen = await tester.createGesture(pointer: _pen, kind: .stylus);
        final palm = await tester.createGesture(kind: .touch);
        final start = center + const Offset(-96, -55);
        final end = center + const Offset(72, -25);

        await _penDown(pen, start, 10);
        await _penMove(pen, start, center + const Offset(-60, -52), .30, 20);
        await _penMove(
          pen,
          center + const Offset(-60, -52),
          center + const Offset(-31, -47),
          .38,
          30,
        );
        await palm.down(center + const Offset(169, 110), timeStamp: _at(40));
        await palm.moveTo(center + const Offset(258, 160), timeStamp: _at(50));
        await _penMove(
          pen,
          center + const Offset(-31, -47),
          center + const Offset(0, -42),
          .49,
          60,
        );
        if (cancelPalm) {
          await palm.cancel(timeStamp: _at(70));
        } else {
          await palm.up(timeStamp: _at(70));
        }
        await _penMove(
          pen,
          center + const Offset(0, -42),
          center + const Offset(31, -35),
          .62,
          80,
        );
        await _penMove(pen, center + const Offset(31, -35), end, .76, 90);
        await pen.up(timeStamp: _at(100));
        await tester.pump();

        _expectStroke(editor, start, end, pressure: .76);
        expect(transform.value.storage, orderedEquals(before));
      }),
      skip: !officePreviewPdfiumAvailable,
    );
  }

  testWidgets(
    'PDF stylus palm already down still draws and fresh touch pinches afterwards',
    (tester) => _withPdfEditor(tester, (editor, center, transform) async {
      final before = transform.value.storage.toList();
      final pen = await tester.createGesture(pointer: _pen, kind: .stylus);
      final palm = await tester.createGesture(kind: .touch);
      final start = center + const Offset(-96, -55);
      final middle = center + const Offset(-54, -50);
      final end = center + const Offset(35, -26);

      await palm.down(center + const Offset(188, 105), timeStamp: _at(10));
      await _penDown(pen, start, 20);
      await _penMove(pen, start, middle, .33, 30);
      await _penMove(pen, middle, center + const Offset(-12, -38), .56, 40);
      await _penMove(pen, center + const Offset(-12, -38), end, .72, 50);
      await pen.up(timeStamp: _at(60));
      await palm.up(timeStamp: _at(70));
      await tester.pump(const Duration(milliseconds: 30));

      _expectStroke(editor, start, end, pressure: .72);
      expect(transform.value.storage, orderedEquals(before));
      final beforePinch = transform.value.getMaxScaleOnAxis();
      final (first, second) = await _pinch(tester, center, start: 110);
      await first.up(timeStamp: _at(170));
      await second.up(timeStamp: _at(180));
      await tester.pump();

      expect(
        transform.value.getMaxScaleOnAxis(),
        greaterThan(beforePinch * 1.1),
      );
      expect(
        editor.coreInfo.pages.expand((page) => page.strokes),
        hasLength(1),
      );
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'PDF stylus palm takes over a live pinch and a canceled pen permits a fresh pinch',
    (tester) => _withPdfEditor(tester, (editor, center, transform) async {
      final initialScale = transform.value.getMaxScaleOnAxis();
      final (first, second) = await _pinch(tester, center, start: 10);
      expect(
        transform.value.getMaxScaleOnAxis(),
        greaterThan(initialScale * 1.1),
      );
      final beforePen = transform.value.storage.toList();
      final pen = await tester.createGesture(pointer: _pen, kind: .stylus);
      final start = center + const Offset(-82, -45);
      final middle = center + const Offset(-40, -40);
      final end = center + const Offset(45, -30);

      await _penDown(pen, start, 70);
      await _penMove(pen, start, middle, .35, 80);
      await _penMove(pen, middle, center + const Offset(3, -34), .57, 90);
      await _penMove(pen, center + const Offset(3, -34), end, .75, 100);
      expect(Pen.currentStroke, isNotNull);
      _expectPenPoints(
        editor.coreInfo.pages.first,
        Pen.currentStroke!,
        start,
        end,
        .75,
      );
      expect(transform.value.storage, orderedEquals(beforePen));
      await pen.cancel(timeStamp: _at(110));
      expect(Pen.currentStroke, isNull);
      final savedAfterCancel = editor.coreInfo.pages
          .expand((page) => page.strokes)
          .length;

      await first.moveTo(center - const Offset(158, 0), timeStamp: _at(120));
      await second.moveTo(center + const Offset(171, 0), timeStamp: _at(130));
      await first.up(timeStamp: _at(140));
      await second.up(timeStamp: _at(150));
      expect(transform.value.storage, orderedEquals(beforePen));

      final beforeFresh = transform.value.getMaxScaleOnAxis();
      final (freshFirst, freshSecond) = await _pinch(
        tester,
        center,
        start: 160,
      );
      await freshFirst.up(timeStamp: _at(220));
      await freshSecond.up(timeStamp: _at(230));
      await tester.pump();
      expect(
        transform.value.getMaxScaleOnAxis(),
        greaterThan(beforeFresh * 1.1),
      );
      expect(
        editor.coreInfo.pages.expand((page) => page.strokes),
        hasLength(savedAfterCancel),
      );
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'PDF stylus retires live Windows trackpad zoom and allows fresh trackpad zoom',
    (tester) => _withPdfEditor(tester, (editor, center, transform) async {
      final initialScale = transform.value.getMaxScaleOnAxis();
      final trackpad = await _trackpadZoom(tester, center, start: 10);
      expect(transform.value.getMaxScaleOnAxis(), greaterThan(initialScale));
      await tester.pump();
      final beforePen = transform.value.storage.toList();
      final pen = await tester.createGesture(pointer: _pen, kind: .stylus);
      final start = center + const Offset(-82, -45);
      final middle = center + const Offset(-40, -40);
      final next = center + const Offset(3, -34);
      final end = center + const Offset(45, -30);

      await _penDown(pen, start, 50);
      await _penMove(pen, start, middle, .35, 60);
      await trackpad.panZoomUpdate(center, scale: 1.7, timeStamp: _at(70));
      await _penMove(pen, middle, next, .57, 80);
      await _penMove(pen, next, end, .75, 90);
      await pen.up(timeStamp: _at(100));
      await trackpad.panZoomUpdate(center, scale: 1.9, timeStamp: _at(110));
      await trackpad.panZoomEnd(timeStamp: _at(120));
      await tester.pump();

      _expectStroke(editor, start, end, pressure: .75);
      expect(transform.value.storage, orderedEquals(beforePen));
      final beforeFresh = transform.value.getMaxScaleOnAxis();
      final freshTrackpad = await _trackpadZoom(tester, center, start: 130);
      await freshTrackpad.panZoomEnd(timeStamp: _at(170));
      await tester.pump();

      expect(transform.value.getMaxScaleOnAxis(), greaterThan(beforeFresh));
      expect(
        editor.coreInfo.pages.expand((page) => page.strokes),
        hasLength(1),
      );
    }, platform: TargetPlatform.windows),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'PDF single page mode saves stylus ink under the original non-first page',
    (tester) async {
      int? savedPage;
      Map<String, Uint8List>? savedFiles;
      await _withPdfEditor(
        tester,
        (editor, _, transform) async {
          const pageIndex = 1;
          final page = editor.coreInfo.pages[pageIndex];
          final id = page.pageId;
          expect(
            editor.revealPage(id, background: page.backgroundImage),
            isTrue,
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('editor-single-page-toggle')),
          );
          await tester.pumpAndSettle();
          expect(editor.currentPageIndex, pageIndex);
          expect(editor.coreInfo.pages.first.renderBox, isNull);
          final center = tester.getCenter(find.byType(InteractiveCanvasViewer));
          expect(editor.onWhichPageIsFocalPoint(center), pageIndex);
          final matrix = transform.value.storage.toList();
          final start = center + const Offset(-80, -44);
          final middle = center + const Offset(-35, -39);
          final end = center + const Offset(55, -23);
          final pen = await tester.createGesture(pointer: _pen, kind: .stylus);
          await _penDown(pen, start, 10);
          await _penMove(pen, start, middle, .38, 20);
          await _penMove(pen, middle, center + const Offset(8, -31), .55, 30);
          await _penMove(pen, center + const Offset(8, -31), end, .72, 40);
          await pen.up(timeStamp: _at(50));
          await tester.pump();

          expect(
            editor.coreInfo.pages.expand((page) => page.strokes),
            hasLength(1),
          );
          _expectPenPoints(page, page.strokes.single, start, end, .72);
          expect(transform.value.storage, orderedEquals(matrix));
          await officePreviewRead(tester, editor.saveToFile);
          expect(savedPage, pageIndex);
          final files = savedFiles!;
          expect(files.keys, containsAll(['main.sbn2', 'main.sbn2.0']));
          final directory = File(editor.coreInfo.filePath).parent.path;
          final reloadPath = '$directory/reloaded-main';
          final reopened = await officePreviewRead(tester, () async {
            for (final entry in files.entries) {
              final suffix = entry.key.substring('main'.length);
              await File('$reloadPath$suffix').writeAsBytes(entry.value);
            }
            final rawPaths = FileManager.shouldUseRawFilePath;
            FileManager.shouldUseRawFilePath = true;
            try {
              return await EditorCoreInfo.loadFromFileContents(
                bsonBytes: await File('$reloadPath.sbn2').readAsBytes(),
                path: reloadPath,
                onlyFirstPage: false,
              );
            } finally {
              FileManager.shouldUseRawFilePath = rawPaths;
            }
          });
          try {
            expect(reopened.initialPageIndex, pageIndex);
            expect(reopened.pages[pageIndex].pageId, id);
            expect(
              (reopened.pages[pageIndex].backgroundImage as PdfEditorImage)
                  .pdfPage,
              pageIndex,
            );
            expect(reopened.pages.first.strokes, isEmpty);
            expect(reopened.pages[pageIndex].strokes, hasLength(1));
            final stored = reopened.pages[pageIndex].strokes.single.points.last;
            final original = page.strokes.single.points.last;
            expect(stored.x, closeTo(original.x, .02));
            expect(stored.y, closeTo(original.y, .02));
          } finally {
            reopened.dispose();
          }
        },
        secondPage: true,
        onSaveSnapshot: (core, index) async {
          if (!core.pages.any((page) => page.strokes.isNotEmpty)) return;
          savedFiles = await SaberInkAdapter.capture(core, index);
          savedPage = index;
        },
      );
    },
    skip: !officePreviewPdfiumAvailable,
  );
}

const _pen = 42;

Duration _at(int milliseconds) => Duration(milliseconds: milliseconds);

Future<TestGesture> _trackpadZoom(
  WidgetTester tester,
  Offset center, {
  required int start,
}) async {
  final trackpad = await tester.createGesture(kind: .trackpad);
  await trackpad.panZoomStart(center, timeStamp: _at(start));
  await trackpad.panZoomUpdate(center, scale: 1.10, timeStamp: _at(start + 10));
  await trackpad.panZoomUpdate(center, scale: 1.25, timeStamp: _at(start + 20));
  await trackpad.panZoomUpdate(center, scale: 1.45, timeStamp: _at(start + 30));
  return trackpad;
}

Future<(TestGesture, TestGesture)> _pinch(
  WidgetTester tester,
  Offset center, {
  required int start,
}) async {
  final first = await tester.createGesture(kind: .touch);
  final second = await tester.createGesture(kind: .touch);
  await first.down(center - const Offset(48, 0), timeStamp: _at(start));
  await second.down(center + const Offset(48, 0), timeStamp: _at(start + 10));
  await first.moveTo(center - const Offset(96, 0), timeStamp: _at(start + 20));
  await second.moveTo(
    center + const Offset(105, 0),
    timeStamp: _at(start + 30),
  );
  await first.moveTo(center - const Offset(125, 0), timeStamp: _at(start + 40));
  await second.moveTo(
    center + const Offset(135, 0),
    timeStamp: _at(start + 50),
  );
  return (first, second);
}

Future<void> _penDown(TestGesture pen, Offset position, int milliseconds) =>
    pen.downWithCustomEvent(
      position,
      PointerDownEvent(
        pointer: _pen,
        kind: .stylus,
        position: position,
        buttons: kPrimaryButton,
        pressure: .22,
        pressureMin: 0,
        pressureMax: 1,
        timeStamp: _at(milliseconds),
      ),
    );

Future<void> _penMove(
  TestGesture pen,
  Offset from,
  Offset to,
  double pressure,
  int milliseconds,
) => pen.updateWithCustomEvent(
  PointerMoveEvent(
    pointer: _pen,
    kind: .stylus,
    position: to,
    delta: to - from,
    buttons: kPrimaryButton,
    pressure: pressure,
    pressureMin: 0,
    pressureMax: 1,
    timeStamp: _at(milliseconds),
  ),
);

void _expectStroke(
  EditorState editor,
  Offset start,
  Offset end, {
  required double pressure,
}) {
  final pages = editor.coreInfo.pages;
  expect(pages.expand((page) => page.strokes), hasLength(1));
  final page = pages.first;
  _expectPenPoints(page, page.strokes.single, start, end, pressure);
}

void _expectPenPoints(
  EditorPage page,
  Stroke stroke,
  Offset start,
  Offset end,
  double pressure,
) {
  expect(stroke.pressureEnabled, isTrue);
  expect(stroke.points.length, greaterThanOrEqualTo(3));
  final range = Rect.fromPoints(start, end).inflate(2);
  final render = page.renderBox!;
  for (final point in stroke.points) {
    final global = render.localToGlobal(Offset(point.x, point.y));
    expect(
      range.contains(global),
      isTrue,
      reason: '$global is not a pen point',
    );
    expect(point.pressure, inInclusiveRange(.22, pressure));
  }
  final last = stroke.points.last;
  expect(
    (render.localToGlobal(Offset(last.x, last.y)) - end).distance,
    lessThan(2),
  );
  expect(last.pressure, closeTo(pressure, .001));
}

Future<void> _withPdfEditor(
  WidgetTester tester,
  Future<void> Function(EditorState, Offset, TransformationController) check, {
  TargetPlatform platform = TargetPlatform.android,
  bool secondPage = false,
  Future<void> Function(EditorCoreInfo, int)? onSaveSnapshot,
}) => withOfficePreviewPdfium(tester, () async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final oldPlatform = debugDefaultTargetPlatformOverride;
  final oldFingerDrawing = stows.editorFingerDrawing.value;
  final oldTool = stows.lastTool.value;
  final oldZoom = stows.lastZoomLock.value;
  final oldPan = stows.lastSingleFingerPanLock.value;
  final oldSinglePageMode = stows.lastSinglePageMode.value;
  final oldPen = Pen.currentPen;
  debugDefaultTargetPlatformOverride = platform;
  stows.editorFingerDrawing.value = false;
  stows.lastTool.value = .fountainPen;
  stows.lastZoomLock.value = false;
  stows.lastSingleFingerPanLock.value = false;
  stows.lastSinglePageMode.value = false;
  Pen.currentPen = Pen.fountainPen();
  final directory = await officePreviewRead(
    tester,
    () => Directory.systemTemp.createTemp('pdf-stylus-palm-'),
  );
  try {
    final file = await officePreviewRead(tester, () async {
      final pdf = File('${directory.path}/palm.pdf');
      return pdf.writeAsBytes(
        await officePreviewPdf(
          PdfColors.white,
          second: secondPage ? PdfColors.blue : null,
        ),
      );
    });
    final path = '${directory.path}/palm.sbn2';
    var loaded = false;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Editor(
            path: path,
            pdfPath: file.path,
            loadSnapshot: () async => EditorCoreInfo(filePath: path),
            onSaveSnapshot: onSaveSnapshot ?? (_, _) async {},
            onLoaded: (_) => loaded = true,
            showDocumentHeader: false,
          ),
        ),
      ),
    );
    final editor = tester.state<EditorState>(find.byType(Editor));
    await officePreviewUntil(
      tester,
      () => loaded && editor.coreInfo.pages.first.renderBox != null,
      'The actual PDF import and first pen canvas must be ready',
    );
    final page = editor.coreInfo.pages.first;
    expect((page.backgroundImage as PdfEditorImage).pdfPage, 0);
    expect(page.strokes, isEmpty);
    final viewer = find.byType(InteractiveCanvasViewer);
    final transform = tester
        .widget<InteractiveCanvasViewer>(viewer)
        .transformationController!;
    final box = page.renderBox!;
    final visible = Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(page.size.bottomRight(Offset.zero)),
    ).intersect(tester.getRect(viewer));
    expect(visible.width, greaterThan(600));
    expect(visible.height, greaterThan(360));
    await check(editor, visible.center, transform);
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    await officePreviewDocumentsClosed(tester);
    await tester.runAsync(() => directory.delete(recursive: true));
    Pen.currentStroke = null;
    Pen.currentPen = oldPen;
    stows.editorFingerDrawing.value = oldFingerDrawing;
    stows.lastTool.value = oldTool;
    stows.lastZoomLock.value = oldZoom;
    stows.lastSingleFingerPanLock.value = oldPan;
    stows.lastSinglePageMode.value = oldSinglePageMode;
    debugDefaultTargetPlatformOverride = oldPlatform;
  }
});
