import 'dart:io';

import 'package:bson/bson.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations, QuillController;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_canvas_background_painter.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/inner_canvas.dart';
import 'package:saber/components/toolbar/editor_bottom_sheet.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/read_only_reason.dart';

import '../utils/test_mock_channel_handlers.dart';

/// A page may have its own pattern (lined, grid, dots, none) in a note of
/// another pattern. Only such notes are written as version 20, which 232 and
/// Windows 226 cannot open; every other note stays version 19, byte for byte.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  /// A sample note with fixed page ids, so its saved bytes do not change from
  /// run to run (a sample without ids gets random ones when it is read).
  Future<EditorCoreInfo> sample(String name) async {
    final core = await EditorCoreInfo.loadFromFileContents(
      bsonBytes: File('test/sbn_examples/$name.sbn2').readAsBytesSync(),
      path: '/page-pattern/$name',
      onlyFirstPage: false,
    );
    // The copy takes over the page's strokes, text and pictures, and is
    // disposed with the note; the replaced page holds nothing of its own.
    for (var i = 0; i < core.pages.length; i++) {
      core.pages[i] = core.pages[i].copyWith(
        pageId: '00000000-0000-4000-8000-00000000000$i',
      );
    }
    return core;
  }

  // SHA-256 of the saved bytes, recorded with the code before this change
  // (2026-11-27, start tree db9fcbe6): the sample as read, then with the
  // note's pattern set to grid.
  const baseline = {
    ('v19_pens', null):
        '197d8fd71c38f30e9317bd6c67894d05c9769e764c22cae6ed2864abb6719ab1',
    ('v19_pens', CanvasBackgroundPattern.grid):
        '197d8fd71c38f30e9317bd6c67894d05c9769e764c22cae6ed2864abb6719ab1',
    ('v19_quill_languages', null):
        'e8377e7dfa23a2429007b621df19b7743a0822a708b76fac58382c92a5403d5f',
    ('v19_quill_languages', CanvasBackgroundPattern.grid):
        '8e1fc8d3b69f6a9647232695c26e432e56969e3f51c41d678f8f6480121c2d9e',
    ('v19_shape_strokes', null):
        '7c930ec6e227d36061d38b207c116315e4411af966e1cf672b4cc10a4e7cbda0',
    ('v19_shape_strokes', CanvasBackgroundPattern.grid):
        '1d07b3d33069e2b623982b178393f052385bdadb875d56ee2d6f2df13ebdafac',
  };

  for (final MapEntry(key: (name, pattern), value: hash) in baseline.entries) {
    for (final pageSaysNotePattern in [false, true]) {
      test('one pattern: $name ${pattern?.name ?? 'as read'}'
          '${pageSaysNotePattern ? ', a page set to the same' : ''} '
          'is version 19 with the bytes of before', () async {
        final core = await sample(name);
        if (pattern != null) core.backgroundPattern = pattern;
        if (pageSaysNotePattern) {
          core.pages.first.backgroundPattern = core.backgroundPattern;
        }
        expect(core.versionToWrite(), 19);
        final (json, _) = core.toJson();
        expect(json['v'], 19);
        for (final page in json['z'] as List) {
          expect((page as Map).containsKey('bp'), isFalse);
        }
        final (bson, _) = core.saveToBinary(currentPageIndex: null);
        expect(sha256.convert(bson).toString(), hash);
        core.dispose();
      });
    }
  }

  test('a page of another pattern makes version 20 and comes back', () async {
    final core = await sample('v19_pens');
    expect(core.backgroundPattern, CanvasBackgroundPattern.grid);
    core.pages[0].backgroundPattern = CanvasBackgroundPattern.none;
    core.pages[1].backgroundPattern = CanvasBackgroundPattern.dots;
    expect(core.versionToWrite(), 20);
    final (json, _) = core.toJson();
    expect(json['v'], 20);
    expect(json['p'], 'grid');
    final pages = (json['z'] as List).cast<Map>();
    // 「빈」 has the serialized name '' (as the note's `p`)
    expect(pages[0]['bp'], CanvasBackgroundPattern.none.name);
    expect(pages[1]['bp'], 'dots');

    final (bson, _) = core.saveToBinary(currentPageIndex: 0);
    final reloaded = await EditorCoreInfo.loadFromFileContents(
      bsonBytes: bson,
      path: '/page-pattern/reloaded',
      onlyFirstPage: false,
    );
    expect(reloaded.readOnlyReason, isNull);
    expect(reloaded.backgroundPattern, CanvasBackgroundPattern.grid);
    // The dotted page was the blank last page; now that it is not empty, a
    // plain blank page follows it, as after any last page with content.
    expect(reloaded.pages.map((page) => page.backgroundPattern), [
      CanvasBackgroundPattern.none,
      CanvasBackgroundPattern.dots,
      null,
    ]);
    expect(reloaded.versionToWrite(), 20);

    // A copy of the page (a duplicate, or the clone a thumbnail draws) keeps it.
    // A copy shares the original's strokes and pictures (this page has no
    // pictures, so disposing the duplicate leaves the original whole) and
    // gets its own text box here, which its dispose takes with it.
    final duplicate = reloaded.pages[1].copyWith(
      newIdentity: true,
      quill: QuillStruct(
        controller: QuillController.basic(),
        focusNode: FocusNode(),
      ),
    );
    expect(duplicate.backgroundPattern, CanvasBackgroundPattern.dots);
    duplicate.dispose();
    final clone = reloaded.pages[1].cloneForRasterization();
    expect(clone.backgroundPattern, CanvasBackgroundPattern.dots);
    clone.disposeClonedData();

    // Back to the note's pattern: version 19 again, no page key.
    reloaded.pages[0].backgroundPattern = null;
    reloaded.pages[1].backgroundPattern = CanvasBackgroundPattern.grid;
    expect(reloaded.versionToWrite(), 19);
    final (back, _) = reloaded.toJson();
    expect(back['v'], 19);
    for (final page in back['z'] as List) {
      expect((page as Map).containsKey('bp'), isFalse);
    }
    core.dispose();
    reloaded.dispose();
  });

  test('a page with a background picture draws and writes no pattern', () {
    final core = EditorCoreInfo(filePath: '/page-pattern/picture')
      ..backgroundPattern = CanvasBackgroundPattern.grid;
    final page = EditorPage(
      backgroundImage: SvgEditorImage(
        id: 0,
        svgString: '<svg height="100" width="100"></svg>',
        svgFile: null,
        pageIndex: 0,
        pageSize: EditorPage.defaultSize,
        onMoveImage: null,
        onDeleteImage: null,
        onMiscChange: null,
        assetCache: core.assetCache,
      ),
      backgroundPattern: CanvasBackgroundPattern.dots,
    );
    core.pages.addAll([page, EditorPage()]);
    expect(core.versionToWrite(), 19);
    final (json, _) = core.toJson();
    expect(json['v'], 19);
    for (final page in json['z'] as List) {
      expect((page as Map).containsKey('bp'), isFalse);
    }
    core.dispose();
  });

  test(
    'a page has its own pattern only when it differs and has no picture',
    () {
      const grid = CanvasBackgroundPattern.grid;
      final follows = EditorPage();
      final same = EditorPage(backgroundPattern: grid);
      final dotted = EditorPage(
        backgroundPattern: CanvasBackgroundPattern.dots,
      );
      final blank = EditorPage(backgroundPattern: CanvasBackgroundPattern.none);
      expect(follows.hasOwnPattern(grid), isFalse);
      expect(same.hasOwnPattern(grid), isFalse);
      expect(dotted.hasOwnPattern(grid), isTrue);
      expect(blank.hasOwnPattern(grid), isTrue);
      expect(dotted.hasOwnPattern(CanvasBackgroundPattern.dots), isFalse);
      final core = EditorCoreInfo(filePath: '/page-pattern/own');
      final pictured = EditorPage(
        backgroundImage: SvgEditorImage(
          id: 0,
          svgString: '<svg height="100" width="100"></svg>',
          svgFile: null,
          pageIndex: 0,
          pageSize: EditorPage.defaultSize,
          onMoveImage: null,
          onDeleteImage: null,
          onMiscChange: null,
          assetCache: core.assetCache,
        ),
        backgroundPattern: CanvasBackgroundPattern.dots,
      );
      expect(pictured.hasOwnPattern(grid), isFalse);
      for (final page in [follows, same, dotted, blank, pictured]) {
        page.dispose();
      }
      core.dispose();
    },
  );

  test('a note newer than this app reads is read-only', () async {
    Future<EditorCoreInfo> read(int version) {
      final core = EditorCoreInfo(filePath: '/page-pattern/version')
        ..pages.add(EditorPage());
      final (json, _) = core.toJson();
      core.dispose();
      json['v'] = version;
      return EditorCoreInfo.loadFromFileContents(
        bsonBytes: BsonCodec.serialize(json).byteList,
        path: '/page-pattern/version',
        onlyFirstPage: false,
      );
    }

    final newest = await read(EditorCoreInfo.newestSbnVersion);
    expect(newest.readOnlyReason, isNull);
    newest.dispose();
    final newer = await read(EditorCoreInfo.newestSbnVersion + 1);
    expect(newer.readOnlyReason, ReadOnlyReason.versionTooNew);
    newer.dispose();
  });

  test('a blank page of its own pattern is not empty', () {
    final plain = EditorPage();
    final dotted = EditorPage(backgroundPattern: CanvasBackgroundPattern.dots);
    expect(plain.isEmpty, isTrue);
    expect(dotted.isEmpty, isFalse);
    plain.dispose();
    dotted.dispose();
  });

  testWidgets('the page draws its own pattern, else the note pattern', (
    tester,
  ) async {
    final core = EditorCoreInfo(filePath: '/page-pattern/canvas')
      ..backgroundPattern = CanvasBackgroundPattern.lined
      ..pages.addAll([
        EditorPage(),
        EditorPage(backgroundPattern: CanvasBackgroundPattern.dots),
      ]);
    Future<CanvasBackgroundPattern> drawn(int pageIndex) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Center(
            child: InnerCanvas(
              key: ValueKey(pageIndex),
              pageIndex: pageIndex,
              width: 500,
              height: 700,
              coreInfo: core,
              currentStroke: null,
              currentStrokeDetectedShape: null,
              currentSelection: null,
              currentToolIsSelect: false,
              currentScale: 1,
            ),
          ),
        ),
      );
      final paint = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter is CanvasBackgroundPainter,
        ),
      );
      return (paint.painter! as CanvasBackgroundPainter).backgroundPattern;
    }

    expect(await drawn(0), CanvasBackgroundPattern.lined);
    expect(await drawn(1), CanvasBackgroundPattern.dots);
    await tester.pumpWidget(const SizedBox());
    core.dispose();
  });

  testWidgets('the end-of-note cleanup keeps a blank page of its own pattern', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(path: '/page-pattern', onSaveSnapshot: (_, _) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.state<EditorState>(find.byType(Editor));
    final pages = editor.coreInfo.pages;
    expect(pages, hasLength(1));

    final dotted = EditorPage(backgroundPattern: CanvasBackgroundPattern.dots);
    pages.addAll([dotted, EditorPage()]);
    editor.removeExcessPages();
    await tester.pump();
    expect(pages, hasLength(3));
    expect(pages[1], same(dotted));

    // the same blank page without its own pattern is cleaned up as before
    dotted.backgroundPattern = null;
    editor.removeExcessPages();
    await tester.pump();
    expect(pages, hasLength(1));
    editor.cancelAutosaveAndMarkSaved();
  });

  test('a page copy can follow the note again (copyWith null)', () {
    final dotted = EditorPage(backgroundPattern: CanvasBackgroundPattern.dots);
    final kept = dotted.copyWith();
    final follows = dotted.copyWith(backgroundPattern: null);
    final lined = dotted.copyWith(
      backgroundPattern: CanvasBackgroundPattern.lined,
    );
    expect(kept.backgroundPattern, CanvasBackgroundPattern.dots);
    expect(follows.backgroundPattern, isNull);
    expect(lined.backgroundPattern, CanvasBackgroundPattern.lined);
    expect(EditorCoreInfo.pagePatternVersion, 20);
    // the copies share the original's text box: only it is disposed
    dotted.dispose();
  });

  test('without patterns (export 「배경 끄기」): no page draws one', () {
    final core = EditorCoreInfo(filePath: '/page-pattern/export')
      ..backgroundPattern = CanvasBackgroundPattern.grid;
    final plain = EditorPage();
    final dotted = EditorPage(backgroundPattern: CanvasBackgroundPattern.dots);
    core.pages.addAll([plain, dotted]);
    final bare = core.withoutPatterns();
    expect(bare.backgroundPattern, CanvasBackgroundPattern.none);
    expect(bare.pages, hasLength(2));
    for (final page in bare.pages) {
      expect(
        page.backgroundPattern ?? bare.backgroundPattern,
        CanvasBackgroundPattern.none,
      );
    }
    expect(bare.pages[1].strokes, same(dotted.strokes));
    // the note itself keeps its patterns
    expect(core.backgroundPattern, CanvasBackgroundPattern.grid);
    expect(dotted.backgroundPattern, CanvasBackgroundPattern.dots);
    core.dispose();
  });

  testWidgets('export 「배경 끄기」 draws no page pattern; with it on, the '
      'pages keep theirs', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(
            path: '/page-pattern-export',
            onSaveSnapshot: (_, _) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.state<EditorState>(find.byType(Editor));
    final core = editor.coreInfo..backgroundPattern = .grid;
    final dotted = EditorPage(backgroundPattern: CanvasBackgroundPattern.dots);
    core.pages.insert(0, dotted);

    // what exportAsPdf and exportAsPng draw
    final bare = editor.exportInfo(false);
    expect(bare.backgroundPattern, CanvasBackgroundPattern.none);
    expect(bare.pages, hasLength(core.pages.length));
    for (final page in bare.pages) {
      expect(
        page.backgroundPattern ?? bare.backgroundPattern,
        CanvasBackgroundPattern.none,
      );
    }
    final kept = editor.exportInfo(true);
    expect(kept, same(core));
    expect(kept.pages.first.backgroundPattern, CanvasBackgroundPattern.dots);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the note taking a page pattern makes the page follow it; '
      'undo and redo put it back', (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(path: '/page-pattern', onSaveSnapshot: (_, _) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.state<EditorState>(find.byType(Editor));
    final core = editor.coreInfo..backgroundPattern = .grid;
    final dotted = EditorPage(backgroundPattern: CanvasBackgroundPattern.dots);
    final lined = EditorPage(backgroundPattern: CanvasBackgroundPattern.lined);
    core.pages.insertAll(0, [dotted, lined]);
    final sheet = editor.bottomSheet(
      tester.element(find.byType(Editor)),
    ) as EditorBottomSheet;

    sheet.setBackgroundPattern(CanvasBackgroundPattern.dots);
    await tester.pump();
    expect(core.backgroundPattern, CanvasBackgroundPattern.dots);
    expect(dotted.backgroundPattern, isNull, reason: 'saved without bp');
    expect(lined.backgroundPattern, CanvasBackgroundPattern.lined);
    expect(core.versionToWrite(), 20);
    // the note on to lined: the page that followed dots goes with it
    sheet.setBackgroundPattern(CanvasBackgroundPattern.lined);
    await tester.pump();
    expect(dotted.backgroundPattern, isNull);
    expect(lined.backgroundPattern, isNull);
    expect(core.versionToWrite(), 19);
    expect(dotted.isEmpty && lined.isEmpty, isTrue);

    editor.undo();
    await tester.pump();
    expect(core.backgroundPattern, CanvasBackgroundPattern.dots);
    expect(lined.backgroundPattern, CanvasBackgroundPattern.lined);
    expect(dotted.backgroundPattern, isNull);
    editor.undo();
    await tester.pump();
    expect(core.backgroundPattern, CanvasBackgroundPattern.grid);
    expect(dotted.backgroundPattern, CanvasBackgroundPattern.dots);
    expect(lined.backgroundPattern, CanvasBackgroundPattern.lined);
    editor.redo();
    await tester.pump();
    expect(core.backgroundPattern, CanvasBackgroundPattern.dots);
    expect(dotted.backgroundPattern, isNull);
    expect(lined.backgroundPattern, CanvasBackgroundPattern.lined);
    editor.redo();
    await tester.pump();
    expect(core.backgroundPattern, CanvasBackgroundPattern.lined);
    expect(lined.backgroundPattern, isNull);
    editor.cancelAutosaveAndMarkSaved();
  });
}
