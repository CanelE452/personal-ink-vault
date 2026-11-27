import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/tool_id.dart';

import '../utils/screen_capture.dart';
import '../utils/test_mock_channel_handlers.dart';

/// Writes screenshots of the toolbar's 노트 추가 window (supplement Task 14)
/// to build/screen-review/supp-t14/app-supp-t14-*.png with the app's fonts
/// at device pixel ratio 2, as the 12th draft's device (`#extras12`): the
/// window open on the tablet (`window`), on a 360 phone scrolled to its
/// bottom (`phone-scrolled`), and the undo notice after a lined page went in
/// (`notice`). Runs only with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/supp-t14');

Future<void> _write(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  debugDisableShadows = false;
  try {
    void mark(RenderObject o) {
      o.markNeedsPaint();
      o.visitChildren(mark);
    }

    mark(boundary.currentContext!.findRenderObject()!);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final object =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await object.toImage(pixelRatio: 2);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/app-supp-t14-$name.png')
          .writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
  }
  expect(tester.takeException(), isNull);
}

void main() {
  FlavorConfig.setup();

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    await FileManager.init();
    final saved = (
      stows.addPagePlace.value,
      stows.addPageRecent.value,
      stows.editorToolbarTools.value,
      stows.pageToolbarLayout.value,
    );
    stows.addPagePlace.value = 'after';
    stows.addPageRecent.value = const ['lined', 'dots'];
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    addTearDown(() {
      stows.addPagePlace.value = saved.$1;
      stows.addPageRecent.value = saved.$2;
      stows.editorToolbarTools.value = saved.$3;
      stows.pageToolbarLayout.value = saved.$4;
    });
  });

  /// A real editor [width] wide over a page area [page] high, on a grid
  /// note of two written pages, with 노트 추가 open, then [then].
  Future<void> shoot(
    WidgetTester tester,
    String name, {
    double width = 586,
    double page = 734,
    Future<void> Function()? then,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    final size = Size(width, 46 + page);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: TranslationProvider(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            theme: ThemeData(
              fontFamily: captureLatin,
              fontFamilyFallback: const [captureKorean],
            ),
            home: Editor(
              path:
                  '/add-page-capture-${DateTime.now().microsecondsSinceEpoch}',
              customTitle: '강의노트 3주차',
              showDocumentHeader: false,
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.state<EditorState>(find.byType(Editor));
    addTearDown(editor.cancelAutosaveAndMarkSaved);
    editor.coreInfo.backgroundPattern = CanvasBackgroundPattern.grid;
    editor.createPage(1);
    for (final (i, page) in editor.coreInfo.pages.take(2).indexed) {
      page.insertStroke(
        Stroke(
          color: const Color(0xFF1E3A5F),
          pressureEnabled: false,
          options: StrokeOptions(size: 6),
          pageIndex: i,
          page: page,
          toolId: ToolId.ballpointPen,
        )..addPoints([
          for (var x = 120.0; x <= 620; x += 20) Offset(x, 260 + (x % 40)),
        ]),
      );
    }
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-insert-page')));
    await tester.pumpAndSettle();
    await then?.call();
    await tester.pumpAndSettle();
    await _write(tester, boundary, name);
  }

  group('add page captures', skip: !_capture, () {
    testWidgets('window', (tester) => shoot(tester, 'window'));
    testWidgets(
      'phone-scrolled',
      (tester) => shoot(
        tester,
        'phone-scrolled',
        width: 360,
        page: 474,
        then: () async {
          await tester.drag(find.text('양식'), const Offset(0, -400));
          await tester.pumpAndSettle();
        },
      ),
    );
    testWidgets(
      'notice',
      (tester) => shoot(
        tester,
        'notice',
        then: () async {
          await tester.tap(find.byKey(const ValueKey('add-page-card-lined')));
          await tester.pumpAndSettle();
        },
      ),
    );
  });
}
