import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/canvas/save_indicator.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_original_preview.dart';
import 'package:saber/pages/office/office_workspace.dart';
import 'package:saber/pages/office/windows_office_editor.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:xml/xml.dart';

import 'windows_flow_harness.dart';

typedef _OfficeSample = ({
  String menuLabel,
  String title,
  String extension,
  String xmlPart,
  String previewRoute,
});

const _word = (
  menuLabel: 'Word 문서 만들기',
  title: '통합 Word 문서',
  extension: 'docx',
  xmlPart: 'word/document.xml',
  previewRoute: 'WindowsOfficeEngine/LibreOffice',
);
const _presentation = (
  menuLabel: '프레젠테이션 만들기',
  title: '통합 프레젠테이션',
  extension: 'pptx',
  xmlPart: 'ppt/slides/slide1.xml',
  previewRoute: 'WindowsOfficeEngine/LibreOffice',
);
const _hwpx = (
  menuLabel: '한글 문서 만들기',
  title: '통합 한글 문서',
  extension: 'hwpx',
  xmlPart: 'Contents/section0.xml',
  previewRoute: 'HwpStructuredOfficeEngine',
);
const _editedHwpxText = '한글 원본 편집 저장 재열기 검증';
const _officeTimeout = Duration(seconds: 90);

Future<void> createOfficeFlow(WindowsFlowHarness h) async {
  final folderId = _selectedFolder(h);
  final baseline = <String, Object?>{};
  for (final sample in [_word, _presentation, _hwpx]) {
    await h.createDocument(sample.menuLabel, sample.title);
    final office = await _workspace(h, sample, waitForFileName: true);
    expect(office.note.folderId, folderId);
    final store = OfficeDocumentStore(office.repository);
    final original = await store.readLatest(office.note);
    _expectOriginal(sample, original, sample.title);
    expect(original.pdfBytes, isNull);
    await h.record(
      '${sample.extension}-created',
      _editionDetails(office, original),
    );

    final preview = await _rasterPreview(h, office, sample, original);
    expect(
      _editionDetails(office, await store.readLatest(office.note)),
      _editionDetails(office, original),
    );

    OfficeEdition latest = original;
    Map<String, Object?>? annotation;
    if (sample == _word) {
      await h.capture('office-word-preview');
    } else if (sample == _presentation) {
      await h.capture('office-presentation-preview');
      await _tapOfficeButton(
        h,
        'office-preview-pdf',
        'start PPT PDF annotation',
      );
      final editor = await _pdfEditor(h, 'created PPT PDF annotation ready');
      latest = await store.readLatest(office.note);
      _expectPdfEdition(latest, original, 'LibreOffice');
      _expectOriginal(sample, latest, sample.title);
      expect(latest.originalBytes, original.originalBytes);
      expect(latest.pdfBytes, preview.pdfBytes);
      await _expectEditorPdf(editor, latest);
      await h.record(
        'pptx-pdf-edition-created',
        _editionDetails(office, latest),
      );
      final page = editor.coreInfo.pages.first;
      final raster = await _pptPdfRaster(h, page);
      final initialInk = (await office.repository.heads(latest.bindingId!))
          .single;
      await _drawPptStylus(h, editor, page, raster);
      annotation = await _pptInkDetails(office, latest, page);
      expect(annotation['parentRevisionIds'], [initialInk.revisionId]);
      await h.record('pptx-pdf-ink-saved', annotation);
    } else {
      await _editHwpx(h, original);
      latest = await store.readLatest(office.note);
      _expectPdfEdition(latest, original, 'ink_hwp_native');
      _expectOriginal(sample, latest, _editedHwpxText);
      expect(latest.originalSha256, isNot(original.originalSha256));
      expect(latest.pdfSha256, isNot(_sha256(preview.pdfBytes)));
      await h.record('hwpx-edition-saved', _editionDetails(office, latest));
      await _rasterPreview(h, office, sample, latest);
    }

    final retained = await store.readLatest(
      office.note,
      revisionId: original.revision.revisionId,
    );
    expect(retained.originalBytes, original.originalBytes);
    expect(retained.pdfBytes, isNull);
    baseline[sample.extension] = {
      'initial': _editionDetails(office, retained),
      'latest': _editionDetails(office, latest),
      'annotation': ?annotation,
    };
    await h.backToLibrary();
    expect(_selectedFolder(h), folderId);
  }
  await _baselineFile(h).writeAsString(jsonEncode(baseline), flush: true);
  await h.record('word-presentation-separate-native-editor-typing', {
    'coverage': 'untested',
  });
}

Future<void> reopenOfficeFlow(WindowsFlowHarness h) async {
  final folderId = _selectedFolder(h);
  final baseline =
      jsonDecode(await _baselineFile(h).readAsString()) as Map<String, dynamic>;
  for (final sample in [_word, _presentation, _hwpx]) {
    await h.openCard(sample.title);
    final office = await _workspace(
      h,
      sample,
      waitForFileName: sample != _presentation,
    );
    expect(office.note.folderId, folderId);
    final store = OfficeDocumentStore(office.repository);
    final saved = baseline[sample.extension] as Map<String, dynamic>;
    final expectedOriginal = saved['initial'] as Map<String, dynamic>;
    final original = await store.readLatest(
      office.note,
      revisionId: expectedOriginal['revisionId'] as String,
    );
    _expectOriginal(sample, original, sample.title);
    expect(_editionDetails(office, original), expectedOriginal);
    final latest = await store.readLatest(office.note);
    expect(_editionDetails(office, latest), saved['latest']);
    _expectOriginal(
      sample,
      latest,
      sample == _hwpx ? _editedHwpxText : sample.title,
    );
    if (sample == _presentation) {
      _expectPdfEdition(latest, original, 'LibreOffice');
      final editor = await _pdfEditor(h, 'reopened PPT PDF annotation ready');
      await _expectEditorPdf(editor, latest);
      final page = editor.coreInfo.pages.first;
      await _pptPdfRaster(h, page);
      final annotation = await _pptInkDetails(office, latest, page);
      expect(annotation, saved['annotation']);
      await h.record('pptx-pdf-ink-reopened', annotation);
    } else {
      if (sample == _hwpx) {
        _expectPdfEdition(latest, original, 'ink_hwp_native');
      }
      await _rasterPreview(h, office, sample, latest);
    }
    await h.record(
      '${sample.extension}-reopened',
      _editionDetails(office, latest),
    );
    await h.backToLibrary();
    expect(_selectedFolder(h), folderId);
  }
}

File _baselineFile(WindowsFlowHarness h) =>
    File('${h.profile.path}/windows-office-baseline.json');

String _selectedFolder(WindowsFlowHarness h) {
  final library = h.tester.widget<LibraryHome>(find.byType(LibraryHome));
  final folder = library.folders.singleWhere(
    (folder) => folder.title == WindowsFlowHarness.folderTitle,
  );
  expect(library.currentFolderId, folder.id);
  return folder.id;
}

String _sha256(Uint8List bytes) => sha256.convert(bytes).toString();

Map<String, Object?> _editionDetails(
  OfficeWorkspace office,
  OfficeEdition edition,
) => {
  'noteId': office.note.id,
  'folderId': office.note.folderId,
  'sourceEntityId': edition.revision.entityId,
  'revisionId': edition.revision.revisionId,
  'parentRevisionIds': edition.revision.parentRevisionIds,
  'originalFileName': edition.originalFileName,
  'originalSha256': edition.originalSha256,
  'pdfSha256': edition.pdfSha256,
  'bindingId': edition.bindingId,
  'pageCount': edition.pageCount,
  'engineVersion': edition.engineVersion,
};

Future<OfficeWorkspace> _workspace(
  WindowsFlowHarness h,
  _OfficeSample sample, {
  required bool waitForFileName,
}) async {
  final workspace = find.byWidgetPredicate(
    (widget) => widget is OfficeWorkspace && widget.note.title == sample.title,
  );
  final fileName = find.descendant(
    of: workspace,
    matching: find.text('${sample.title}.${sample.extension}'),
  );
  await h.waitUntil(
    '${sample.extension} office workspace ready',
    () =>
        workspace.evaluate().length == 1 &&
        (!waitForFileName || fileName.evaluate().length == 1),
    timeout: _officeTimeout,
  );
  return h.tester.widget<OfficeWorkspace>(workspace);
}

void _expectOriginal(_OfficeSample sample, OfficeEdition edition, String text) {
  expect(edition.originalFileName, '${sample.title}.${sample.extension}');
  expect(_sha256(edition.originalBytes), edition.originalSha256);
  final archive = ZipDecoder().decodeBytes(edition.originalBytes, verify: true);
  try {
    final part = archive.findFile(sample.xmlPart);
    expect(
      part,
      isNotNull,
      reason: '${sample.extension} contains its body XML',
    );
    final xml = XmlDocument.parse(utf8.decode(part!.content));
    final bodyText = xml.descendants
        .whereType<XmlElement>()
        .where((node) => node.name.local == 't')
        .map((node) => node.innerText)
        .join();
    expect(bodyText, text);
  } finally {
    archive.clearSync();
  }
}

void _expectPdfEdition(
  OfficeEdition edition,
  OfficeEdition original,
  String engine,
) {
  expect(edition.revision.revisionId, isNot(original.revision.revisionId));
  expect(edition.revision.parentRevisionIds, [original.revision.revisionId]);
  expect(edition.bindingId, isNotEmpty);
  expect(edition.engineVersion, contains(engine));
  expect(edition.pageCount, greaterThan(0));
  expect(edition.pdfBytes, isNotNull);
  expect(ascii.decode(edition.pdfBytes!.sublist(0, 5)), '%PDF-');
  expect(_sha256(edition.pdfBytes!), edition.pdfSha256);
}

Finder _inOffice(Finder matching) =>
    find.descendant(of: find.byType(OfficeWorkspace), matching: matching);

bool _enabled(WidgetTester tester, Finder button) =>
    button.evaluate().length == 1 &&
    tester.widget<ButtonStyleButton>(button).onPressed != null;

Future<void> _tapOfficeButton(
  WindowsFlowHarness h,
  String key,
  String step,
) async {
  final button = _inOffice(find.byKey(ValueKey(key)));
  await h.waitUntil(
    '$step enabled',
    () => _enabled(h.tester, button),
    timeout: _officeTimeout,
  );
  await h.tap(button, step, reveal: true);
}

Future<OfficeOriginalPreview> _rasterPreview(
  WindowsFlowHarness h,
  OfficeWorkspace office,
  _OfficeSample sample,
  OfficeEdition edition,
) async {
  if (edition.pdfBytes == null) {
    await _tapOfficeButton(
      h,
      'office-original-preview-load',
      'load ${sample.extension} original preview',
    );
  }
  final preview = _inOffice(find.byType(OfficeOriginalPreview));
  final page = find.descendant(of: preview, matching: find.byType(PdfPageView));
  final raster = find.descendant(of: page, matching: find.byType(RawImage));
  final error = _inOffice(
    find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          ((widget.data ?? '').startsWith('WindowsOfficeException(') ||
              (widget.data ?? '').startsWith('PlatformException(')),
    ),
  );
  await h.waitUntil('${sample.extension} PDF page loaded', () {
    if (error.evaluate().isNotEmpty) {
      throw StateError(
        '${sample.extension} preview: ${h.tester.widget<Text>(error.first).data}',
      );
    }
    return page.evaluate().length == 1;
  }, timeout: const Duration(seconds: 225));
  await h.tester.ensureVisible(preview);
  await h.waitUntil(
    '${sample.extension} PDF page raster ready',
    () =>
        raster.evaluate().length == 1 &&
        h.tester.widget<RawImage>(raster).image != null,
    timeout: _officeTimeout,
  );
  final viewed = h.tester.widget<OfficeOriginalPreview>(preview);
  final document = h.tester.widget<PdfPageView>(page).document;
  final image = h.tester.widget<RawImage>(raster).image!;
  final pdfHash = _sha256(viewed.pdfBytes);
  expect(document, isNotNull);
  final pageCount = document!.pages.length;
  expect(pageCount, greaterThan(0));
  expect(
    viewed.sourceKey,
    endsWith('/${office.note.id}/${edition.revision.revisionId}/$pdfHash'),
  );
  if (edition.pdfBytes != null) {
    expect(viewed.pdfBytes, edition.pdfBytes);
    expect(pageCount, edition.pageCount);
  }
  await h.record('${sample.extension}-original-preview-raster', {
    ..._editionDetails(office, edition),
    'previewOrigin': edition.pdfBytes == null
        ? sample.previewRoute
        : 'saved edition',
    'renderedPdfSha256': pdfHash,
    'renderedPageCount': pageCount,
    'rasterWidth': image.width,
    'rasterHeight': image.height,
  });
  return viewed;
}

Future<EditorState> _pdfEditor(WindowsFlowHarness h, String step) async {
  final editor = _inOffice(find.byType(Editor));
  final error = _inOffice(find.textContaining('필기를 열 수 없습니다'));
  await h.waitUntil(step, () {
    if (error.evaluate().isNotEmpty) {
      throw StateError('$step: ${h.tester.widget<Text>(error.first).data}');
    }
    if (editor.evaluate().length != 1) return false;
    final state = h.tester.state<EditorState>(editor);
    final page = state.coreInfo.pages.firstOrNull;
    return !state.coreInfo.readOnly &&
        state.savingState.value == SavingState.saved &&
        page != null &&
        page.backgroundImage is PdfEditorImage &&
        find.byKey(page.innerCanvasKey).evaluate().length == 1;
  }, timeout: _officeTimeout);
  return h.tester.state<EditorState>(editor);
}

Future<void> _expectEditorPdf(EditorState editor, OfficeEdition edition) async {
  final backgrounds = editor.coreInfo.pages
      .map((page) => page.backgroundImage)
      .whereType<PdfEditorImage>()
      .toList();
  expect(backgrounds, hasLength(edition.pageCount!));
  for (var index = 0; index < backgrounds.length; index++) {
    final background = backgrounds[index];
    expect(background.pdfPage, index);
    final bytes =
        background.pdfBytes ?? await background.pdfFile!.readAsBytes();
    expect(bytes, edition.pdfBytes);
  }
}

Future<Finder> _pptPdfRaster(WindowsFlowHarness h, EditorPage page) async {
  final view = find.descendant(
    of: find.byKey(page.innerCanvasKey),
    matching: find.byType(PdfPageView),
  );
  final raster = find.descendant(of: view, matching: find.byType(RawImage));
  await h.waitUntil('first PPT annotation page raster ready', () {
    if (raster.evaluate().length != 1) return false;
    final image = h.tester.widget<RawImage>(raster).image;
    return image != null && image.width > 0 && image.height > 0;
  }, timeout: _officeTimeout);
  expect(h.tester.widget<PdfPageView>(view).pageNumber, 1);
  return raster;
}

Future<void> _drawPptStylus(
  WindowsFlowHarness h,
  EditorState editor,
  EditorPage page,
  Finder raster,
) async {
  expect(page.strokes, isEmpty);
  final tester = h.tester;
  final canvas = _inOffice(find.byType(InteractiveCanvasViewer));
  final visible = tester.getRect(raster).intersect(tester.getRect(canvas));
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
  await h.waitUntil(
    'PPT PDF stylus stroke saved',
    () =>
        page.strokes.isNotEmpty &&
        editor.savingState.value == SavingState.saved,
  );
}

Future<Map<String, Object?>> _pptInkDetails(
  OfficeWorkspace office,
  OfficeEdition edition,
  EditorPage page,
) async {
  expect(page.strokes, hasLength(1));
  expect(page.strokes.single.length, greaterThan(2));
  final ink = (await office.repository.heads(edition.bindingId!)).single;
  expect(ink.ownerNoteId, office.note.id);
  return {
    'pageId': page.pageId,
    'strokes': page.strokes.length,
    'points': page.strokes.single.length,
    'inkRevisionId': ink.revisionId,
    'parentRevisionIds': ink.parentRevisionIds,
  };
}

Future<void> _editHwpx(WindowsFlowHarness h, OfficeEdition original) async {
  await _tapOfficeButton(h, 'office-edit-original', 'open HWPX source editor');
  final editor = find.byType(WindowsOfficeEditor);
  await h.waitUntil(
    'HWPX editor opened',
    () => editor.evaluate().length == 1,
    timeout: _officeTimeout,
  );
  final snapshot = h.tester.widget<WindowsOfficeEditor>(editor).snapshot;
  expect(snapshot.sourceSha256, original.originalSha256);
  expect(snapshot.paragraphs, isNotEmpty);
  final paragraph = snapshot.paragraphs.first;
  final field = find.descendant(
    of: editor,
    matching: find.byKey(ValueKey('office-paragraph-${paragraph.id}')),
  );
  await h.tap(field, 'focus first HWPX paragraph', reveal: true);
  expect(h.tester.widget<TextField>(field).readOnly, isFalse);
  expect(h.tester.widget<TextField>(field).controller!.text, _hwpx.title);
  await h.tester.enterText(field, _editedHwpxText);
  await h.waitUntil(
    'edited HWPX paragraph visible',
    () => h.tester.widget<TextField>(field).controller!.text == _editedHwpxText,
  );
  await h.capture('office-hwpx-edited');
  await h.record('hwpx-source-paragraph-edited', {
    'paragraphId': paragraph.id,
    'sourceSha256': snapshot.sourceSha256,
    'marker': _editedHwpxText,
  });
  final save = find.descendant(
    of: editor,
    matching: find.widgetWithText(FilledButton, '저장하고 닫기'),
  );
  await h.waitUntil('HWPX save enabled', () => _enabled(h.tester, save));
  await h.tap(save, 'save and close HWPX source editor');
  await h.waitUntil(
    'HWPX editor closed after saving',
    () =>
        editor.evaluate().isEmpty &&
        find.byType(OfficeWorkspace).evaluate().length == 1,
    timeout: _officeTimeout,
  );
}
