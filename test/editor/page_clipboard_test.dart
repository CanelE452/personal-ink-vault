import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show Document, QuillController;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/page_clipboard.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

final _photoBytes = Uint8List.fromList(List.generate(64, (i) => (i * 7) % 256));
final _pdfBytes = Uint8List.fromList(List.generate(80, (i) => (i * 3) % 256));

EditorCoreInfo _note(String path, CanvasBackgroundPattern pattern) {
  final core = EditorCoreInfo(filePath: path);
  core.backgroundPattern = pattern;
  return core;
}

PngEditorImage _photo(EditorCoreInfo core, int id) => PngEditorImage(
  id: id,
  assetCache: core.assetCache,
  extension: '.png',
  imageProvider: MemoryImage(_photoBytes),
  pageIndex: 0,
  pageSize: const Size(100, 200),
  onMoveImage: null,
  onDeleteImage: null,
  onMiscChange: null,
  newImage: false,
  dstRect: const Rect.fromLTWH(10, 20, 30, 40),
);

Future<PageClip> _clip(
  EditorPage page,
  EditorCoreInfo note, {
  Future<Uint8List?> Function(Uint8List, int)? extract,
}) => clipPage(
  page,
  notePattern: note.backgroundPattern,
  assetCache: note.assetCache,
  extractPdfPage: extract,
);

EditorPage _paste(PageClip clip, EditorCoreInfo note) => pastePage(
  clip,
  sbnPath: note.filePath,
  assetCache: note.assetCache,
  notePattern: note.backgroundPattern,
  pageIndex: 0,
);

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    FlavorConfig.setup();
    await FileManager.init();
  });

  test(
    'a page with a photo pasted into another note keeps the photo bytes',
    () async {
      final a = _note('/a', CanvasBackgroundPattern.none);
      final b = _note('/b', CanvasBackgroundPattern.none);
      final page = EditorPage(pageId: newId(), images: [_photo(a, 3)]);
      final clip = await _clip(page, a);
      b.pages.add(_paste(clip, b));

      final (json, assets) = b.toJson();
      final bytes = await assets.getBytes(0);
      final read = EditorPage.fromJson(
        (json['z'] as List).first as Map<String, dynamic>,
        inlineAssets: [Uint8List.fromList(bytes)],
        readOnly: false,
        fileVersion: EditorCoreInfo.newestSbnVersion,
        sbnPath: '/b',
        assetCache: b.assetCache,
      );
      expect(assets.length, 1);
      expect(bytes, _photoBytes);
      expect(read.images, hasLength(1));
      final provider = (read.images.first as PngEditorImage).imageProvider;
      expect((provider as MemoryImage).bytes, _photoBytes);
    },
  );

  test('pasting twice gives fresh page and link ids', () async {
    final a = _note('/a', CanvasBackgroundPattern.none);
    final b = _note('/b', CanvasBackgroundPattern.none);
    final page = EditorPage(
      pageId: newId(),
      images: [_photo(a, 3)],
      links: [
        PageLink(
          id: newId(),
          rect: const Rect.fromLTWH(0, 0, 10, 10),
          target: 'https://example.com',
        ),
      ],
    );
    final clip = await _clip(page, a);
    final one = _paste(clip, b);
    final two = _paste(clip, b);

    expect({page.pageId, one.pageId, two.pageId}, hasLength(3));
    expect({
      page.links.single.id,
      one.links.single.id,
      two.links.single.id,
    }, hasLength(3));
    expect(one.images.single.id, -1);
    expect(two.images.single.id, -1);
  });

  test('a page following its note pattern keeps that look in a note with '
      'another pattern', () async {
    final a = _note('/a', CanvasBackgroundPattern.lined);
    final grid = _note('/b', CanvasBackgroundPattern.grid);
    final lined = _note('/c', CanvasBackgroundPattern.lined);
    final clip = await _clip(EditorPage(pageId: newId()), a);

    expect(_paste(clip, grid).backgroundPattern, CanvasBackgroundPattern.lined);
    expect(_paste(clip, lined).backgroundPattern, isNull);
  });

  test('text and strokes survive', () async {
    final a = _note('/a', CanvasBackgroundPattern.none);
    final b = _note('/b', CanvasBackgroundPattern.none);
    final page = EditorPage(
      pageId: newId(),
      quill: QuillStruct(
        controller: QuillController(
          document: Document.fromJson([
            {'insert': 'hello\n'},
          ]),
          selection: const TextSelection.collapsed(offset: 0),
        ),
        focusNode: FocusNode(),
      ),
    );
    for (var i = 0; i < 2; i++) {
      page.strokes.add(
        Stroke(
          color: Colors.blue,
          pressureEnabled: false,
          options: StrokeOptions(size: 5),
          pageIndex: 0,
          page: page,
          toolId: ToolId.ballpointPen,
        )..addPoints([for (var x = 0.0; x < 100; x += 10) Offset(x, 10.0 * i)]),
      );
    }
    final pasted = _paste(await _clip(page, a), b);
    expect(pasted.strokes, hasLength(2));
    expect(
      pasted.quill.controller.document.toDelta().toJson(),
      page.quill.controller.document.toDelta().toJson(),
    );
  });

  PdfEditorImage pdfBackground(EditorCoreInfo core) => PdfEditorImage(
    id: 0,
    assetCache: core.assetCache,
    pdfBytes: _pdfBytes,
    pdfFile: null,
    pdfPage: 2,
    pageIndex: 0,
    pageSize: const Size(100, 200),
    naturalSize: const Size(100, 200),
    onMoveImage: null,
    onDeleteImage: null,
    onMiscChange: null,
  );

  /// Pastes [clip] into a new note, writes it, and reads its page back.
  Future<EditorPage> pasteAndReread(PageClip clip) async {
    final b = _note('/b', CanvasBackgroundPattern.none);
    final pasted = _paste(clip, b);
    if (pasted.backgroundImage != null) {
      expect(pasted.backgroundImage!.id, -1);
    }
    b.pages.add(pasted);
    final (json, assets) = b.toJson();
    return EditorPage.fromJson(
      (json['z'] as List).first as Map<String, dynamic>,
      inlineAssets: [
        for (var i = 0; i < assets.length; i++)
          Uint8List.fromList(await assets.getBytes(i)),
      ],
      readOnly: false,
      fileVersion: EditorCoreInfo.newestSbnVersion,
      sbnPath: '/b',
      assetCache: b.assetCache,
    );
  }

  test('pdf page falls back to the whole pdf when extraction fails', () async {
    final a = _note('/a', CanvasBackgroundPattern.none);
    final page = EditorPage(pageId: newId(), backgroundImage: pdfBackground(a));
    final clip = await _clip(page, a, extract: (_, _) async => null);
    expect(clip.assets.single, _pdfBytes);
    expect((clip.json['b'] as Map)['pdfi'], 2);
    expect(clip.pattern, isNull);

    final read = await pasteAndReread(clip);
    final pdf = read.backgroundImage! as PdfEditorImage;
    expect(pdf.pdfBytes, _pdfBytes);
    expect(pdf.pdfPage, 2);
  });

  test('a cut pdf page keeps the cut bytes and page 0 after pasting', () async {
    final a = _note('/a', CanvasBackgroundPattern.none);
    final page = EditorPage(pageId: newId(), backgroundImage: pdfBackground(a));
    final one = Uint8List.fromList([1, 2, 3]);
    Uint8List? seen;
    int? seenPage;
    final cut = await _clip(
      page,
      a,
      extract: (pdf, index) async {
        seen = pdf;
        seenPage = index;
        return one;
      },
    );
    expect(seen, _pdfBytes);
    expect(seenPage, 2);
    expect(cut.assets.single, one);
    expect((cut.json['b'] as Map)['pdfi'], 0);

    final read = await pasteAndReread(cut);
    final pdf = read.backgroundImage! as PdfEditorImage;
    expect(pdf.pdfBytes, one);
    expect(pdf.pdfPage, 0);
  });

  test('a page with its own pattern keeps it unless the note has it', () async {
    final a = _note('/a', CanvasBackgroundPattern.lined);
    final own = EditorPage(
      pageId: newId(),
      backgroundPattern: CanvasBackgroundPattern.grid,
    );
    final clip = await _clip(own, a);
    expect(clip.pattern, CanvasBackgroundPattern.grid);

    final grid = _note('/b', CanvasBackgroundPattern.grid);
    final dots = _note('/c', CanvasBackgroundPattern.dots);
    expect(_paste(clip, grid).backgroundPattern, isNull);
    expect(_paste(clip, dots).backgroundPattern, CanvasBackgroundPattern.grid);
  });

  test('a page with a background picture ignores its own pattern', () async {
    final a = _note('/a', CanvasBackgroundPattern.lined);
    final page = EditorPage(
      pageId: newId(),
      backgroundImage: pdfBackground(a),
      backgroundPattern: CanvasBackgroundPattern.grid,
    );
    final clip = await _clip(page, a);
    expect(clip.pattern, isNull);
    final b = _note('/b', CanvasBackgroundPattern.dots);
    expect(_paste(clip, b).backgroundPattern, isNull);
  });

  test(
    'a slow pdf copy ending after a later copy does not replace it',
    () async {
      addTearDown(() => PageClipboard.current.value = null);
      final a = _note('/a', CanvasBackgroundPattern.none);
      final pdfPage = EditorPage(
        pageId: newId(),
        backgroundImage: pdfBackground(a),
      );
      final plain = EditorPage(pageId: newId(), images: [_photo(a, 3)]);
      final extracting = Completer<Uint8List?>();

      // the pdf page's copy waits for its page to be cut out of the pdf
      final first = PageClipboard.hold(
        () => _clip(pdfPage, a, extract: (_, _) => extracting.future),
      );
      final second = PageClipboard.hold(() => _clip(plain, a));
      expect(await second, isTrue);
      final held = PageClipboard.current.value;
      expect(held, isNotNull);
      expect(held!.json['b'], isNull, reason: 'the plain page');

      extracting.complete(Uint8List.fromList([1, 2, 3]));
      expect(await first, isFalse);
      expect(PageClipboard.current.value, same(held));
    },
  );
}
