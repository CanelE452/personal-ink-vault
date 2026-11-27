import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/page_clipboard.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/read_only_reason.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// A 1 x 1 transparent PNG (a picture the engine can decode).
final _photoBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
]);

/// The page operations the thumbnail menu and the drag-to-reorder call
/// (Task 3 of the page thumbnail menu).
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
    PageClipboard.current.value = null;
  });

  Future<EditorState> mountEditor(
    WidgetTester tester,
    String path, {
    bool snapshot = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1200, 1600)),
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(
              key: ValueKey(path),
              path: path,
              onSaveSnapshot: snapshot ? (_, _) async {} : null,
              // an empty note, without reading a file (that needs real time)
              loadSnapshot: snapshot
                  ? null
                  : () async => EditorCoreInfo(filePath: path),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  /// Makes the note [count] pages long, each with one stroke whose first
  /// x is its own number, and returns the page ids in order.
  Future<List<String>> threePages(
    WidgetTester tester,
    EditorState editor, {
    int count = 3,
    int? filled,
  }) async {
    while (editor.coreInfo.pages.length < count) {
      editor.insertPageAfter(editor.coreInfo.pages.length - 1);
    }
    for (var i = 0; i < (filled ?? count); i++) {
      final page = editor.coreInfo.pages[i];
      page.insertStroke(
        Stroke(
          color: const Color(0xFF1E88E5),
          pressureEnabled: false,
          options: StrokeOptions(size: 10),
          pageIndex: i,
          page: page,
          toolId: ToolId.ballpointPen,
        )..addPoints([
          for (var x = 0.0; x < 5; x++) Offset(100 + i * 50 + x, 300),
        ]),
      );
    }
    await tester.pump();
    return [for (final page in editor.coreInfo.pages) page.pageId];
  }

  List<String> idsOf(EditorState editor) => [
    for (final page in editor.coreInfo.pages) page.pageId,
  ];

  /// Every stroke and picture knows the position of its page.
  void expectPageIndexes(EditorState editor) {
    for (var i = 0; i < editor.coreInfo.pages.length; i++) {
      final page = editor.coreInfo.pages[i];
      for (final stroke in page.strokes) {
        expect(stroke.pageIndex, i, reason: 'stroke on page $i');
      }
      for (final image in page.images) {
        expect(image.pageIndex, i, reason: 'picture on page $i');
      }
    }
  }

  PngEditorImage photoOn(EditorState editor, int pageIndex) {
    final page = editor.coreInfo.pages[pageIndex];
    final photo = PngEditorImage(
      id: editor.coreInfo.nextImageId++,
      assetCache: editor.coreInfo.assetCache,
      extension: '.png',
      imageProvider: MemoryImage(_photoBytes),
      pageIndex: pageIndex,
      pageSize: page.size,
      onMoveImage: null,
      onDeleteImage: null,
      onMiscChange: null,
      newImage: false,
      dstRect: const Rect.fromLTWH(10, 20, 30, 40),
    );
    page.images.add(photo);
    return photo;
  }

  /// A picture lets its image go 5 s after it leaves the screen; that timer
  /// must have run by the test's end.
  Future<void> closeWithPictures(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('moving a page and undoing puts it back', (tester) async {
    final editor = await mountEditor(tester, '/page-ops-move');
    final ids = await threePages(tester, editor);

    editor.movePage(0, 2);
    await tester.pump();
    expect(idsOf(editor), [ids[1], ids[2], ids[0]]);
    for (var i = 0; i < 3; i++) {
      for (final stroke in editor.coreInfo.pages[i].strokes) {
        expect(stroke.pageIndex, i);
      }
    }
    // the first note page's stroke (x 100) is now on page 2
    expect(editor.coreInfo.pages[2].strokes.single.points.first.x, 100);

    editor.undo();
    await tester.pump();
    expect(idsOf(editor), ids);
    expect(editor.coreInfo.pages[0].strokes.single.pageIndex, 0);

    editor.redo();
    await tester.pump();
    expect(idsOf(editor), [ids[1], ids[2], ids[0]]);
    expect(editor.coreInfo.pages[2].strokes.single.pageIndex, 2);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('moving to the same place records nothing', (tester) async {
    final editor = await mountEditor(tester, '/page-ops-same');
    expect(editor.history.canUndo, isFalse);
    editor.movePage(0, 0);
    expect(editor.history.canUndo, isFalse);
    await threePages(tester, editor);
    final last = editor.history.peekUndo();

    editor.movePage(1, 1);
    await tester.pump();

    expect(identical(editor.history.peekUndo(), last), isTrue);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets(
    'cut removes the page, keeps the clip, and one undo restores it',
    (tester) async {
      final editor = await mountEditor(tester, '/page-ops-cut');
      final ids = await threePages(tester, editor, count: 2);

      await tester.runAsync(() => editor.cutPage(0));
      await tester.pump();
      expect(editor.coreInfo.pages, hasLength(1));
      expect(idsOf(editor), [ids[1]]);
      expect(PageClipboard.current.value, isNotNull);

      editor.undo();
      await tester.pump();
      expect(idsOf(editor), ids);
      expect(PageClipboard.current.value, isNotNull);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets('after a cut, its undo and its redo every page index is right', (
    tester,
  ) async {
    final editor = await mountEditor(tester, '/page-ops-cut-index');
    final ids = await threePages(tester, editor, count: 2);
    photoOn(editor, 1);

    await tester.runAsync(() => editor.cutPage(0));
    await tester.pump();
    expect(idsOf(editor), [ids[1]]);
    expect(editor.coreInfo.pages.single.strokes, hasLength(1));
    expect(editor.coreInfo.pages.single.images, hasLength(1));
    expectPageIndexes(editor);

    editor.undo();
    await tester.pump();
    expect(idsOf(editor), ids);
    expectPageIndexes(editor);

    editor.redo();
    await tester.pump();
    expect(idsOf(editor), [ids[1]]);
    expectPageIndexes(editor);
    editor.cancelAutosaveAndMarkSaved();
    await closeWithPictures(tester);
  });

  testWidgets('moving the last page to the front, undo and redo', (
    tester,
  ) async {
    final editor = await mountEditor(tester, '/page-ops-move-front');
    final ids = await threePages(tester, editor);

    editor.movePage(2, 0);
    await tester.pump();
    expect(idsOf(editor), [ids[2], ids[0], ids[1]]);
    expectPageIndexes(editor);

    editor.undo();
    await tester.pump();
    expect(idsOf(editor), ids);
    expectPageIndexes(editor);

    editor.redo();
    await tester.pump();
    expect(idsOf(editor), [ids[2], ids[0], ids[1]]);
    expectPageIndexes(editor);
    editor.cancelAutosaveAndMarkSaved();
  });

  /// A pen stroke on page [i] as the editor records one: its own undo step.
  void drawOn(EditorState editor, int i) {
    final page = editor.coreInfo.pages[i];
    final stroke = Stroke(
      color: const Color(0xFF43A047),
      pressureEnabled: false,
      options: StrokeOptions(size: 10),
      pageIndex: i,
      page: page,
      toolId: ToolId.ballpointPen,
    )..addPoints([for (var x = 0.0; x < 5; x++) Offset(300 + x, 500)]);
    page.insertStroke(stroke);
    editor.history.recordChange(
      EditorHistoryItem(
        type: EditorHistoryItemType.draw,
        pageIndex: i,
        strokes: [stroke],
        images: const [],
      ),
    );
  }

  /// Makes the note's pages as one read from a file is (no undo steps):
  /// page i has one stroke when [filled] says so; returns the page ids.
  Future<List<String>> plainPages(
    WidgetTester tester,
    EditorState editor,
    List<bool> filled,
  ) async {
    editor.createPage(filled.length - 2);
    for (final (i, full) in filled.indexed) {
      if (!full) continue;
      final page = editor.coreInfo.pages[i];
      page.insertStroke(
        Stroke(
          color: const Color(0xFF1E88E5),
          pressureEnabled: false,
          options: StrokeOptions(size: 10),
          pageIndex: i,
          page: page,
          toolId: ToolId.ballpointPen,
        )..addPoints([
          for (var x = 0.0; x < 5; x++) Offset(100 + i * 50 + x, 300),
        ]),
      );
    }
    await tester.pump();
    expect(editor.history.canUndo, isFalse);
    return [for (final page in editor.coreInfo.pages) page.pageId];
  }

  /// What the eraser does to [stroke] on page [i]: takes it out, tidies the
  /// empty pages at the end, and records it.
  void eraseOn(EditorState editor, int i, Stroke stroke) {
    editor.coreInfo.pages[i].strokes.remove(stroke);
    editor.removeExcessPages();
    editor.history.recordChange(
      EditorHistoryItem(
        type: EditorHistoryItemType.erase,
        pageIndex: i,
        strokes: [stroke],
        images: const [],
      ),
    );
  }

  testWidgets(
    'an empty page put in and moved to the end is not tidied away while '
    'the history holds it: each undo and redo brings its step back',
    (tester) async {
      final editor = await mountEditor(tester, '/page-ops-move-tidied');
      // A, B and the spare empty page S
      final ids = await plainPages(tester, editor, [true, true, false]);
      editor.insertPageAfter(0); // A, E, B, S
      final added = editor.coreInfo.pages[1];
      expect(added.isEmpty, isTrue);
      editor.movePage(1, 3); // A, B, S, E
      await tester.pump();
      expect(idsOf(editor), [...ids, added.pageId]);

      drawOn(editor, 0);
      await tester.pump();
      editor.undo(); // the stroke: E stays, its steps hold it
      await tester.pump();
      expect(idsOf(editor), [...ids, added.pageId]);

      editor.undo(); // the move
      await tester.pump();
      expect(idsOf(editor), [ids[0], added.pageId, ids[1], ids[2]]);
      editor.undo(); // the page E put in
      await tester.pump();
      expect(idsOf(editor), ids, reason: 'A and B stay');
      expect(editor.coreInfo.pages[0].strokes, hasLength(1));
      expect(editor.coreInfo.pages[1].strokes, hasLength(1));
      expectPageIndexes(editor);

      editor.redo(); // E back after A
      editor.redo(); // moved to the end again
      editor.redo(); // the stroke on A
      await tester.pump();
      expect(idsOf(editor), [...ids, added.pageId]);
      expect(editor.coreInfo.pages[0].strokes, hasLength(2));
      expect(editor.coreInfo.pages[1].strokes, hasLength(1), reason: 'B');
      expectPageIndexes(editor);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets(
    'an empty page in the middle dragged to the end stays while the move is '
    'held, and undoing the move puts it back where it was',
    (tester) async {
      final editor = await mountEditor(tester, '/page-ops-move-middle');
      // A, an empty X, B and the spare empty page S
      final ids = await plainPages(tester, editor, [true, false, true, false]);
      editor.movePage(1, 3); // A, B, S, X
      drawOn(editor, 0);
      await tester.pump();

      editor.undo(); // the stroke; X is held by the move
      await tester.pump();
      expect(idsOf(editor), [ids[0], ids[2], ids[3], ids[1]]);
      editor.undo(); // the move
      await tester.pump();
      expect(idsOf(editor), ids);
      expect(editor.coreInfo.pages[2].strokes, hasLength(1), reason: 'B');
      expectPageIndexes(editor);

      editor.redo();
      editor.redo();
      await tester.pump();
      expect(idsOf(editor), [ids[0], ids[2], ids[3], ids[1]]);
      expect(editor.coreInfo.pages[0].strokes, hasLength(2));
      expectPageIndexes(editor);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets(
    'a stroke erased before an empty page was moved to the end comes back '
    'on its own page',
    (tester) async {
      final editor = await mountEditor(tester, '/page-ops-move-erase');
      // A, B and the spare empty page S
      final ids = await plainPages(tester, editor, [true, true, false]);
      drawOn(editor, 1); // B has two strokes, so erasing one keeps it
      editor.insertPageAfter(0); // A, E, B, S
      final added = editor.coreInfo.pages[1];
      final b = editor.coreInfo.pages[2];
      final erased = b.strokes.last;
      eraseOn(editor, 2, erased);
      editor.movePage(1, 3); // A, B, S, E
      expect(idsOf(editor), [ids[0], ids[1], ids[2], added.pageId]);
      drawOn(editor, 0);
      await tester.pump();

      // the stroke on A, the move, the erase
      editor.undo();
      editor.undo();
      editor.undo();
      await tester.pump();
      expect(b.strokes, hasLength(2), reason: 'back on B');
      expect(b.strokes, contains(erased));
      expect(editor.coreInfo.pages[2], same(b));
      expect(idsOf(editor).take(3), [ids[0], added.pageId, ids[1]]);
      expect(editor.coreInfo.pages.last.isEmpty, isTrue);
      editor.undo(); // the page put in
      await tester.pump();
      expect(idsOf(editor).take(2), [ids[0], ids[1]]);
      expect(b.strokes, hasLength(2));
      expectPageIndexes(editor);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets('a page carrying only a link is kept, and so is the empty '
      'page after it', (tester) async {
    final editor = await mountEditor(tester, '/page-ops-link-tidy');
    // A, L with only a link, and the spare empty page S
    final ids = await plainPages(tester, editor, [true, false, false]);
    editor.coreInfo.pages[1].links.add(
      const PageLink(
        id: 'only-link',
        rect: Rect.fromLTWH(100, 100, 200, 40),
        target: 'https://example.com/a',
      ),
    );
    editor.removeExcessPages();
    await tester.pump();
    expect(idsOf(editor), ids, reason: 'the note still ends with S');
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets(
    'a page carrying only a link, moved back into a note that got shorter, '
    'is followed by an empty page',
    (tester) async {
      final editor = await mountEditor(tester, '/page-ops-link-move');
      // A, empty X and Y, L with only a link, and the spare empty page S
      final ids = await plainPages(tester, editor, [
        true,
        false,
        false,
        false,
        false,
      ]);
      final link = editor.coreInfo.pages[3];
      link.links.add(
        const PageLink(
          id: 'only-link',
          rect: Rect.fromLTWH(100, 100, 200, 40),
          target: 'https://example.com/a',
        ),
      );
      editor.movePage(3, 0); // L, A, X, Y, S
      drawOn(editor, 1);
      await tester.pump();

      editor.undo(); // the stroke on A; S and Y are tidied away
      await tester.pump();
      expect(idsOf(editor), [ids[3], ids[0], ids[1]]);
      editor.undo(); // the move: L at 3 again
      await tester.pump();
      expect(editor.coreInfo.pages[3], same(link));
      expect(editor.coreInfo.pages, hasLength(5));
      expect(editor.coreInfo.pages.last.links, isEmpty);
      expect(editor.coreInfo.pages.last.isEmpty, isTrue);
      expectPageIndexes(editor);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets('a page put in after the spare one stays until its put-in is '
      'undone', (tester) async {
    final editor = await mountEditor(tester, '/page-ops-after-spare');
    final ids = await plainPages(tester, editor, [true, false]);
    editor.insertPageAfter(1); // A, S, E
    final added = editor.coreInfo.pages[2];
    drawOn(editor, 0);
    await tester.pump();

    editor.undo(); // the stroke; E is held by its put-in
    await tester.pump();
    expect(idsOf(editor), [...ids, added.pageId]);
    editor.undo(); // the put-in
    await tester.pump();
    expect(idsOf(editor), ids);
    expect(editor.coreInfo.pages[0].strokes, hasLength(1));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets(
    'a page moved to the front of a note that then got shorter goes back to '
    'its own place: a stroke erased on it before comes back on it',
    (tester) async {
      final editor = await mountEditor(tester, '/page-ops-move-shorter');
      // A, empty X and Y, C with two strokes, and the spare empty page S
      final ids = await plainPages(tester, editor, [
        true,
        false,
        false,
        true,
        false,
      ]);
      final c = editor.coreInfo.pages[3];
      drawOn(editor, 3);
      final erased = c.strokes.last;
      eraseOn(editor, 3, erased);
      editor.movePage(3, 0); // C, A, X, Y, S
      drawOn(editor, 1);
      await tester.pump();

      editor.undo(); // the stroke on A; S and Y are tidied away
      await tester.pump();
      expect(idsOf(editor), [ids[3], ids[0], ids[1]]);
      editor.undo(); // the move: C at 3 again, empty pages before and after
      await tester.pump();
      expect(idsOf(editor).take(2), [ids[0], ids[1]]);
      expect(editor.coreInfo.pages, hasLength(5));
      expect(editor.coreInfo.pages[2].isEmpty, isTrue);
      expect(editor.coreInfo.pages[3], same(c));
      expect(editor.coreInfo.pages.last.isEmpty, isTrue);
      expectPageIndexes(editor);
      editor.undo(); // the erase: back on C
      await tester.pump();
      expect(c.strokes, contains(erased));
      expect(c.strokes, hasLength(2));
      expectPageIndexes(editor);

      editor.redo(); // the erase
      editor.redo(); // the move
      await tester.pump();
      expect(editor.coreInfo.pages.first, same(c));
      expect(c.strokes, hasLength(1));
      expectPageIndexes(editor);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets(
    'a stroke erased after a page was put in, then tidied, comes back at its '
    'place once the put-in is undone',
    (tester) async {
      final editor = await mountEditor(tester, '/page-ops-insert-erase');
      // A, an empty X, B with stroke s2, and the spare empty page S
      final ids = await plainPages(tester, editor, [true, false, true, false]);
      final s2 = editor.coreInfo.pages[2].strokes.single;
      editor.insertPageAfter(1); // A, X, E, B, S
      eraseOn(editor, 3, s2); // B and S are empty now
      drawOn(editor, 0);
      await tester.pump();

      editor.undo(); // the stroke on A
      editor.undo(); // the erase
      editor.undo(); // the put-in
      await tester.pump();
      expect(idsOf(editor).take(2), [ids[0], ids[1]]);
      expect(editor.coreInfo.pages[1].isEmpty, isTrue, reason: 'X');
      expect(editor.coreInfo.pages[2].strokes, [s2], reason: 'where B was');
      expect(editor.coreInfo.pages.last.isEmpty, isTrue);
      expectPageIndexes(editor);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets('the empty last page cannot be deleted or cut', (tester) async {
    final editor = await mountEditor(tester, '/page-ops-spare');
    final ids = await threePages(tester, editor, count: 3, filled: 2);
    final last = editor.history.peekUndo();
    expect(editor.canDeletePage(2), isFalse);
    expect(editor.canDeletePage(1), isTrue);

    editor.deletePageAt(2);
    await tester.runAsync(() => editor.cutPage(2));
    await tester.pump();

    expect(idsOf(editor), ids);
    expect(PageClipboard.current.value, isNull);
    expect(identical(editor.history.peekUndo(), last), isTrue);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('deleting a filled last page keeps the spare page', (
    tester,
  ) async {
    final editor = await mountEditor(tester, '/page-ops-last');
    final ids = await threePages(tester, editor, count: 4, filled: 3);

    editor.deletePageAt(2);
    await tester.pump();
    expect(idsOf(editor), [ids[0], ids[1], ids[3]]);
    expectPageIndexes(editor);

    editor.undo();
    await tester.pump();
    expect(idsOf(editor), ids);
    expectPageIndexes(editor);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('out of range indexes do nothing', (tester) async {
    final editor = await mountEditor(tester, '/page-ops-range');
    final ids = await threePages(tester, editor, count: 2);
    final last = editor.history.peekUndo();

    for (final index in [-1, 2, 9]) {
      editor.deletePageAt(index);
      await tester.runAsync(() => editor.copyPage(index));
      await tester.runAsync(() => editor.cutPage(index));
    }
    editor.insertPageBefore(-1);
    editor.insertPageBefore(3);
    expect(PageClipboard.current.value, isNull);
    await tester.runAsync(() => editor.copyPage(0));
    editor.pastePageAfter(-2);
    editor.pastePageAfter(2);
    await tester.pump();

    expect(idsOf(editor), ids);
    expect(identical(editor.history.peekUndo(), last), isTrue);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('delete and cut do nothing on the only page', (tester) async {
    final editor = await mountEditor(tester, '/page-ops-only');
    expect(editor.coreInfo.pages, hasLength(1));
    expect(editor.canDeletePage(0), isFalse);
    final id = editor.coreInfo.pages.single.pageId;
    final hadUndo = editor.history.canUndo;

    editor.deletePageAt(0);
    await tester.runAsync(() => editor.cutPage(0));
    await tester.pump();

    expect(idsOf(editor), [id]);
    expect(PageClipboard.current.value, isNull);
    expect(editor.history.canUndo, hadUndo);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('paste after inserts a fresh copy and undo removes it', (
    tester,
  ) async {
    final editor = await mountEditor(tester, '/page-ops-paste');
    final ids = await threePages(tester, editor, count: 2);
    final photo = photoOn(editor, 0);

    await tester.runAsync(() => editor.copyPage(0));
    editor.pastePageAfter(1);
    await tester.pump();

    expect(editor.coreInfo.pages, hasLength(3));
    final pasted = editor.coreInfo.pages[2];
    expect(pasted.pageId, isNot(ids[0]));
    expect(pasted.pageId, isNot(ids[1]));
    final pastedPhoto = pasted.images.single;
    expect(pastedPhoto.id, isNot(photo.id));
    expect(pastedPhoto.id, isNot(-1));
    expect(pastedPhoto.id, lessThan(editor.coreInfo.nextImageId));
    expect(pastedPhoto.pageIndex, 2);

    editor.undo();
    await tester.pump();
    expect(idsOf(editor), ids);
    editor.cancelAutosaveAndMarkSaved();
    await closeWithPictures(tester);
  });

  testWidgets('a pasted picture and paper picture answer to the editor: '
      'moving and deleting are undo steps', (tester) async {
    final editor = await mountEditor(tester, '/page-ops-paste-picture');
    await threePages(tester, editor, count: 2);
    photoOn(editor, 0);
    final paper = photoOn(editor, 0);
    editor.coreInfo.pages[0].images.remove(paper);
    editor.coreInfo.pages[0].backgroundImage = paper;

    await tester.runAsync(() => editor.copyPage(0));
    editor.pastePageAfter(1);
    await tester.pump();
    final pasted = editor.coreInfo.pages[2];
    final photo = pasted.images.single;
    for (final image in [photo, pasted.backgroundImage!]) {
      expect(image.onMoveImage, editor.onMoveImage);
      expect(image.onDeleteImage, editor.onDeleteImage);
      expect(image.onMiscChange, editor.autosaveAfterDelay);
    }

    photo.onMoveImage?.call(photo, const Rect.fromLTRB(5, 0, 5, 0));
    expect(editor.history.peekUndo().type, EditorHistoryItemType.move);
    expect(editor.history.peekUndo().images, [photo]);

    photo.onDeleteImage?.call(photo);
    await tester.pump();
    expect(pasted.images, isEmpty);
    expect(editor.history.canUndo, isTrue);
    expect(editor.history.peekUndo().type, EditorHistoryItemType.erase);
    editor.undo();
    await tester.pump();
    expect(pasted.images, [photo]);
    editor.cancelAutosaveAndMarkSaved();
    await closeWithPictures(tester);
  });

  testWidgets('pasting twice gives different page and picture ids', (
    tester,
  ) async {
    final editor = await mountEditor(tester, '/page-ops-twice');
    final ids = await threePages(tester, editor, count: 2);
    final photo = photoOn(editor, 0);

    await tester.runAsync(() => editor.copyPage(0));
    editor.pastePageAfter(1);
    editor.pastePageAfter(1);
    await tester.pump();

    expect(editor.coreInfo.pages, hasLength(4));
    final one = editor.coreInfo.pages[2];
    final two = editor.coreInfo.pages[3];
    expect({ids[0], ids[1], one.pageId, two.pageId}, hasLength(4));
    final pictureIds = [photo.id, one.images.single.id, two.images.single.id];
    expect(pictureIds.toSet(), hasLength(3));
    expect(pictureIds, isNot(contains(-1)));
    expectPageIndexes(editor);
    editor.cancelAutosaveAndMarkSaved();
    await closeWithPictures(tester);
  });

  testWidgets('a pasted page survives save and reopen in another note', (
    tester,
  ) async {
    final a = await mountEditor(tester, '/page-ops-a');
    photoOn(a, 0);
    await tester.runAsync(() => a.copyPage(0));
    expect(PageClipboard.current.value, isNotNull);
    a.cancelAutosaveAndMarkSaved();
    await closeWithPictures(tester);

    final b = await mountEditor(tester, '/page-ops-b', snapshot: false);
    b.pastePageAfter(0);
    await tester.pump();
    expect(b.coreInfo.pages[1].images, hasLength(1));
    await tester.runAsync(b.saveToFile);
    final path = b.coreInfo.filePath;
    b.cancelAutosaveAndMarkSaved();
    await closeWithPictures(tester);

    final reopened = await tester.runAsync(
      () => EditorCoreInfo.loadFromFilePath(path),
    );
    final images = [for (final page in reopened!.pages) ...page.images];
    expect(images, hasLength(1));
    final provider = (images.single as PngEditorImage).imageProvider;
    // a saved picture is read back from its own file beside the note
    expect(provider, isA<FileImage>());
    final bytes = await tester.runAsync(
      () => (provider as FileImage).file.readAsBytes(),
    );
    expect(bytes, _photoBytes);
    final file = FileManager.getFile('$path${Editor.extension}');
    await tester.runAsync(() async {
      if (file.existsSync()) await file.delete();
    });
  });

  for (final readOnly in [false, true])
    testWidgets(
      readOnly
          ? 'read-only note ignores move, cut, paste, delete, insert and clear'
          : 'locked note ignores move, cut, paste, delete, insert and clear',
      (tester) async {
        final path = '/page-ops-locked-$readOnly';
        final editor = await mountEditor(tester, path);
        final ids = await threePages(tester, editor, count: 2);
        await tester.runAsync(() => editor.copyPage(0));
        final clip = PageClipboard.current.value;
        if (readOnly) {
          editor.coreInfo.readOnlyReason = ReadOnlyReason.versionTooNew;
        } else {
          editor.inkLocked.value = true;
        }
        addTearDown(() => editor.inkLocked.value = false);
        final undoLength = editor.history.canUndo;
        final strokes = [
          for (final page in editor.coreInfo.pages) page.strokes.length,
        ];

        editor.movePage(0, 1);
        await tester.runAsync(() => editor.cutPage(0));
        editor.pastePageAfter(0);
        editor.deletePageAt(0);
        editor.insertPageBefore(0);
        editor.insertPageAfter(0);
        editor.clearPage(0);
        await tester.pump();

        expect(idsOf(editor), ids);
        expect([
          for (final page in editor.coreInfo.pages) page.strokes.length,
        ], strokes);
        expect(strokes.first, greaterThan(0), reason: 'a page to clear');
        expect(PageClipboard.current.value, same(clip));
        expect(editor.history.canUndo, undoLength);
        editor.inkLocked.value = false;
        editor.cancelAutosaveAndMarkSaved();
      },
    );

  testWidgets('a locked note can still copy a page', (tester) async {
    final editor = await mountEditor(tester, '/page-ops-locked-copy');
    final ids = await threePages(tester, editor, count: 2);
    editor.inkLocked.value = true;
    addTearDown(() => editor.inkLocked.value = false);

    await tester.runAsync(() => editor.copyPage(1));

    expect(PageClipboard.current.value, isNotNull);
    expect(idsOf(editor), ids, reason: 'copying changes nothing');
    editor.inkLocked.value = false;
    editor.cancelAutosaveAndMarkSaved();
  });
}
