import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import 'windows_flow_harness.dart';

const _blockTitle = '통합 블록 페이지';
const _blockText = 'Windows에서 입력한 첫 문단을 저장했습니다.';
const _markdownTitle = '통합 Markdown';
const _wikiLabel = '연결된 블록 페이지';
const _inkTitle = '통합 페이지 노트';
const _pdfTitle = 'native-flow';
const _pdfFileName = '$_pdfTitle.pdf';
const _ioTimeout = Duration(seconds: 20);

final _library = find.byType(LibraryHome);
final _blockPage = find.byType(BlockPageEditor);
final _blockField = find.descendant(
  of: _blockPage,
  matching: find.byType(TextField),
);
final _markdown = find.byType(MarkdownEditor);
final _wikiText = find.byWidgetPredicate(
  (widget) =>
      widget is SelectableText &&
      (widget.data ?? widget.textSpan?.toPlainText()) == _wikiLabel,
);
final _editor = find.byType(Editor);

String _markdownText(String blockId) =>
    '# Windows 통합 메모\n\n'
    '뒤로 가기로 저장하는 Markdown 본문입니다.\n\n'
    '[[$blockId|$_wikiLabel]]\n\n'
    '#통합 #연구/윈도우';

LibraryHome _home(WindowsFlowHarness h) => h.tester.widget(_library);

// The app owns the controller in its private workspace State.
WorkspaceController _readWorkspace(WindowsFlowHarness h) {
  final workspace = h.tester.state(find.byType(StudyWorkspace)) as dynamic;
  return workspace.controller as WorkspaceController;
}

Future<void> _selectFolder(WindowsFlowHarness h, {required bool create}) async {
  if (_home(h).currentFolderId != null) {
    await h.tap(
      find.byKey(const ValueKey('library-root')),
      'open root library',
    );
    await h.waitUntil(
      'root library visible',
      () => _library.evaluate().isNotEmpty && _home(h).currentFolderId == null,
    );
  }

  const folderTitle = WindowsFlowHarness.folderTitle;
  if (create) {
    await h.tap(
      find.byKey(const ValueKey('library-create-button')),
      'open folder creation menu',
    );
    await h.tap(find.text('새 폴더'), 'choose 새 폴더', reveal: true);
    final dialog = find.byType(AlertDialog);
    final name = find.descendant(of: dialog, matching: find.byType(TextField));
    await h.waitUntil('folder name dialog', () => name.evaluate().length == 1);
    await h.tester.enterText(name, folderTitle);
    await h.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(FilledButton, '확인'),
      ),
      'confirm folder name',
    );
  }

  await h.waitUntil(
    'root folder card available',
    () => _home(h).folders.any((folder) => folder.title == folderTitle),
  );
  final folder = _home(h).folders.singleWhere((f) => f.title == folderTitle);
  expect(folder.parentId, isNull);
  await h.openCard(folderTitle, folder: true);
  await h.waitUntil(
    'selected folder breadcrumb',
    () =>
        _home(h).currentFolderId == folder.id &&
        find.widgetWithText(TextButton, folderTitle).evaluate().isNotEmpty,
  );
  await h.record(
    create ? 'library-folder-created' : 'library-folder-reopened',
    {'title': folderTitle, 'folderId': folder.id},
  );
}

String _folderNoteId(WindowsFlowHarness h, String title) {
  final home = _home(h);
  return home.notes
      .singleWhere(
        (note) => note.title == title && note.folderId == home.currentFolderId,
      )
      .id;
}

Future<void> _verifyBlockPage(WindowsFlowHarness h, String step) async {
  await h.waitUntil(step, () => _blockField.evaluate().length == 1);
  final block = h.tester
      .state<BlockPageEditorState>(_blockPage)
      .document
      .blocks
      .single;
  expect(block.type, 'paragraph');
  expect(block.text, _blockText);
  expect(h.tester.widget<TextField>(_blockField).controller!.text, _blockText);
  await h.record(step, {'title': _blockTitle, 'paragraph': block.text});
}

Future<void> _verifyMarkdown(
  WindowsFlowHarness h,
  String blockId,
  String step,
) async {
  final preview = find.descendant(
    of: _markdown,
    matching: find.byType(MarkdownPreview),
  );
  await h.waitUntil(step, () => preview.evaluate().length == 1);
  expect(
    h.tester.widget<MarkdownPreview>(preview).source,
    _markdownText(blockId),
  );
  expect(_wikiText, findsOneWidget);
  final workspace = _readWorkspace(h);
  final note =
      workspace.knowledge!.documents[workspace.activeSession!.note.id]!;
  expect(note.tags, unorderedEquals(['통합', '연구', '연구/윈도우']));
  await h.record(step, {
    'title': _markdownTitle,
    'wikiTargetId': blockId,
    'tags': note.tags.toList()..sort(),
  });
}

Future<void> _followWikiLink(WindowsFlowHarness h) async {
  final editable = find.descendant(
    of: _wikiText,
    matching: find.byType(EditableText),
  );
  await h.tester.ensureVisible(_wikiText);
  await h.waitUntil(
    'wiki link laid out',
    () => editable.evaluate().length == 1,
  );
  final render = h.tester.state<EditableTextState>(editable).renderEditable;
  final firstGlyph = render
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1))
      .single;
  final point = render.localToGlobal(firstGlyph.toRect().center);
  expect(
    h.tester.getRect(find.byType(MarkdownPreview)).contains(point),
    isTrue,
  );
  await h.tester.tapAt(point);
}

Future<EditorPage> _firstInkPage(
  WindowsFlowHarness h,
  String title, {
  bool pdf = false,
}) async {
  await h.waitUntil('$title writable first page', () {
    if (_editor.evaluate().length != 1) return false;
    final editor = h.tester.state<EditorState>(_editor);
    final core = editor.coreInfo;
    if (core.readOnly ||
        core.pages.isEmpty ||
        editor.savingState.value != .saved) {
      return false;
    }
    final page = core.pages.first;
    return (page.backgroundImage is PdfEditorImage) == pdf &&
        find.byKey(page.innerCanvasKey).evaluate().length == 1;
  }, timeout: pdf ? const Duration(seconds: 45) : _ioTimeout);
  return h.tester.state<EditorState>(_editor).coreInfo.pages.first;
}

Future<Finder> _verifyPdfRaster(
  WindowsFlowHarness h,
  EditorPage page,
  String step,
) async {
  final view = find.descendant(
    of: find.byKey(page.innerCanvasKey),
    matching: find.byType(PdfPageView),
  );
  final raster = find.descendant(of: view, matching: find.byType(RawImage));
  await h.waitUntil(step, () {
    if (raster.evaluate().length != 1) return false;
    final image = h.tester.widget<RawImage>(raster).image;
    return image != null && image.width > 0 && image.height > 0;
  }, timeout: const Duration(seconds: 45));
  final pdf = h.tester.widget<PdfPageView>(view);
  final image = h.tester.widget<RawImage>(raster).image!;
  expect(pdf.pageNumber, 1);
  expect(pdf.document!.pages.first.isLoaded, isTrue);
  final pages = h.tester.state<EditorState>(_editor).coreInfo.pages;
  expect(
    pages.where((p) => p.backgroundImage is PdfEditorImage).length,
    pdf.document!.pages.length,
  );
  await h.record(step, {
    'pageId': page.pageId,
    'pdfPages': pdf.document!.pages.length,
    'widthPx': image.width,
    'heightPx': image.height,
  });
  return raster;
}

Future<String> _verifyPdfOriginal(WindowsFlowHarness h, String step) async {
  final session = _readWorkspace(h).activeSession!;
  final note = session.note;
  final repository = session.repository;
  expect(repository.formatVersion, 2);
  expect(note.title, _pdfTitle);
  expect(note.documentKind, VaultDocumentKind.pdf);
  expect(note.sourceEntityId, isNotNull);
  final revisions = await repository.revisions().timeout(_ioTimeout);
  final source = revisions
      .where((r) => r.entityId == note.sourceEntityId)
      .single;
  expect(source.ownerNoteId, note.id);
  expect(source.kind, EntityKind.attachment);
  expect(source.deleted, isFalse);
  expect(source.parentRevisionIds, isEmpty);
  expect(source.blobs.keys, [_pdfFileName]);
  final original = await repository.readFiles(source).timeout(_ioTimeout);
  final fixture = await h.fixturePdf.readAsBytes().timeout(_ioTimeout);
  expect(original[_pdfFileName], orderedEquals(fixture));
  final hash = sha256.convert(fixture).toString();
  expect(source.blobs[_pdfFileName]!.hash, hash);
  await h.record(step, {
    'sourceRevisionId': source.revisionId,
    'fileName': _pdfFileName,
    'bytes': fixture.length,
    'sha256': hash,
  });
  return source.revisionId;
}

Future<void> _drawStylus(
  WindowsFlowHarness h,
  EditorPage page,
  Finder surface,
  String step,
) async {
  expect(page.strokes, isEmpty);
  final tester = h.tester;
  final visible = tester
      .getRect(surface)
      .intersect(tester.getRect(find.byType(InteractiveCanvasViewer)));
  expect(visible.width, greaterThan(48));
  expect(visible.height, greaterThan(48));
  Offset point(double x, double y) => Offset(
    visible.left + visible.width * x,
    visible.top + visible.height * y,
  );

  final gesture = await tester.startGesture(point(0.34, 0.44), kind: .stylus);
  const path = [
    (0.38, 0.39),
    (0.42, 0.40),
    (0.46, 0.47),
    (0.50, 0.51),
    (0.54, 0.48),
    (0.59, 0.41),
  ];
  for (final (index, (x, y)) in path.indexed) {
    await gesture.moveTo(
      point(x, y),
      timeStamp: Duration(milliseconds: 18 * (index + 1)),
    );
  }
  await gesture.up(timeStamp: const Duration(milliseconds: 144));
  await h.waitUntil(step, () => page.strokes.isNotEmpty);
  await _recordStroke(h, page, step);
}

Future<void> _recordStroke(
  WindowsFlowHarness h,
  EditorPage page,
  String step, {
  bool persisted = false,
}) async {
  expect(page.strokes, hasLength(1));
  expect(page.strokes.single.length, greaterThan(2));
  await h.record(step, {
    'pageId': page.pageId,
    'strokes': page.strokes.length,
    'points': page.strokes.single.length,
    if (persisted)
      'inkRevisionId': _readWorkspace(h).activeSession!.inkParents.single,
  });
}

Future<void> createLibraryFlow(WindowsFlowHarness h) async {
  await _selectFolder(h, create: true);

  await h.createDocument('블록 페이지', _blockTitle);
  await h.tap(find.text('첫 문단 추가'), 'add first paragraph');
  await h.waitUntil(
    'first paragraph field',
    () => _blockField.evaluate().length == 1,
  );
  await h.tester.enterText(_blockField, _blockText);
  await _verifyBlockPage(h, 'block-paragraph-entered');
  await h.backToLibrary();
  final blockId = _folderNoteId(h, _blockTitle);
  await h.openCard(_blockTitle);
  await _verifyBlockPage(h, 'block-paragraph-saved-card-reopen');
  await h.backToLibrary();

  await h.createDocument('Markdown', _markdownTitle);
  final source = find.descendant(
    of: _markdown,
    matching: find.byType(TextField),
  );
  await h.tap(find.byTooltip('원문 편집'), 'show Markdown source');
  await h.waitUntil(
    'Markdown source field',
    () => source.evaluate().length == 1,
  );
  await h.tester.enterText(source, _markdownText(blockId));
  await h.tester.pump();
  expect(
    h.tester.widget<TextField>(source).controller!.text,
    _markdownText(blockId),
  );
  expect(h.tester.widget<MarkdownEditor>(_markdown).dirty, isTrue);
  await h.record('markdown-source-entered', {'title': _markdownTitle});
  await h.backToLibrary();
  await h.openCard(_markdownTitle);
  await _verifyMarkdown(h, blockId, 'markdown-saved-card-reopen');
  await h.capture('library-markdown-link');
  await _followWikiLink(h);
  await _verifyBlockPage(h, 'markdown-link-opened-block-page');
  expect(_readWorkspace(h).activeSession!.note.id, blockId);
  await h.backToLibrary();

  await h.createDocument('페이지 노트', _inkTitle);
  final blank = await _firstInkPage(h, _inkTitle);
  await _drawStylus(
    h,
    blank,
    find.byKey(blank.innerCanvasKey),
    'blank-ink-entered',
  );
  final blankPoints = blank.strokes.single.length;
  await h.backToLibrary();
  await h.openCard(_inkTitle);
  final savedBlank = await _firstInkPage(h, _inkTitle);
  expect(savedBlank.pageId, blank.pageId);
  expect(savedBlank.strokes.single.length, blankPoints);
  await _recordStroke(
    h,
    savedBlank,
    'blank-ink-saved-card-reopen',
    persisted: true,
  );
  await h.backToLibrary();

  expect(h.fixturePdf.uri.pathSegments.last, _pdfFileName);
  final folderId = _home(h).currentFolderId;
  final inbox = StudyWorkspace.pendingDocumentImport;
  expect(inbox.pending, isEmpty);
  var acknowledged = false;
  expect(
    inbox.enqueue(
      h.fixturePdf.path,
      onRelease: () async {
        acknowledged = true;
      },
    ),
    isTrue,
  );
  final imported = await _firstInkPage(h, _pdfTitle, pdf: true);
  await h.waitUntil(
    'PDF intake acknowledged',
    () => acknowledged && inbox.pending.isEmpty && !inbox.processing,
  );
  expect(_readWorkspace(h).activeSession!.note.folderId, folderId);
  final raster = await _verifyPdfRaster(
    h,
    imported,
    'pdf-imported-and-rasterized',
  );
  final sourceId = await _verifyPdfOriginal(
    h,
    'pdf-imported-original-verified',
  );
  await _drawStylus(h, imported, raster, 'pdf-ink-entered');
  final pdfPoints = imported.strokes.single.length;
  await h.backToLibrary();
  await h.openCard(_pdfTitle);
  final savedPdf = await _firstInkPage(h, _pdfTitle, pdf: true);
  expect(savedPdf.pageId, imported.pageId);
  await _verifyPdfRaster(h, savedPdf, 'pdf-raster-card-reopen');
  expect(savedPdf.strokes.single.length, pdfPoints);
  await _recordStroke(
    h,
    savedPdf,
    'pdf-ink-saved-card-reopen',
    persisted: true,
  );
  expect(await _verifyPdfOriginal(h, 'pdf-original-card-reopen'), sourceId);
  await h.backToLibrary();
}

Future<void> reopenLibraryFlow(WindowsFlowHarness h) async {
  await _selectFolder(h, create: false);
  final blockId = _folderNoteId(h, _blockTitle);
  await h.openCard(_markdownTitle);
  await _verifyMarkdown(h, blockId, 'markdown-persisted-after-restart');
  await h.backToLibrary();

  await h.openCard(_blockTitle);
  await _verifyBlockPage(h, 'block-paragraph-persisted-after-restart');
  await h.backToLibrary();

  await h.openCard(_inkTitle);
  final blank = await _firstInkPage(h, _inkTitle);
  await _recordStroke(
    h,
    blank,
    'blank-ink-persisted-after-restart',
    persisted: true,
  );
  await h.backToLibrary();

  await h.openCard(_pdfTitle);
  final pdf = await _firstInkPage(h, _pdfTitle, pdf: true);
  await _verifyPdfRaster(h, pdf, 'pdf-raster-after-restart');
  await _recordStroke(
    h,
    pdf,
    'pdf-ink-persisted-after-restart',
    persisted: true,
  );
  await _verifyPdfOriginal(h, 'pdf-original-persisted-after-restart');
  await h.capture('library-pdf-reopened');
  await h.backToLibrary();
}
