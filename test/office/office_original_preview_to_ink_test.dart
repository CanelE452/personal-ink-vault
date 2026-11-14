import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_page_link.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_original_preview.dart';
import 'package:saber/pages/office/office_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';
import 'annotation_store_test.dart' show annotationOfficeFile;
import 'office_original_preview_test.dart'
    show
        OfficePreviewDocumentTracker,
        officePreviewDocumentsClosed,
        officePreviewPdf,
        officePreviewPdfiumAvailable,
        officePreviewRead,
        officePreviewUntil,
        withOfficePreviewPdfium;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  testWidgets(
    'historical Office original page opens the matching ink page past an inserted blank',
    (tester) => _withFixture(tester, (fixture) async {
      final saved = await officePreviewRead(tester, fixture.seedHistorical);
      final before = await officePreviewRead(tester, fixture.revisionIds);
      await fixture.mount(tester);
      await _expectPreview(tester, saved.latest.pdfSha256!, 1);
      await _selectEdition(tester, saved.historical.revision.revisionId);
      await _expectPreview(tester, saved.historical.pdfSha256!, 1);
      await _next(tester);
      await _expectPreview(tester, saved.historical.pdfSha256!, 2);

      final editor = await fixture.openInk(tester);
      final pages = editor.coreInfo.pages;
      expect(pages, hasLength(4));
      expect(pages.last.isEmpty, isTrue);
      expect(pages[1].backgroundImage, isNull);
      expect(pages[2].pageId, saved.pageId);
      expect(pages[2].strokes, hasLength(1));
      expect((pages[2].backgroundImage as PdfEditorImage).pdfPage, 1);
      expect(
        editor.currentPageIndex,
        2,
        reason: 'Original PDF page 2 belongs to ink index 2, after the blank.',
      );
      final visible = pages[editor.currentPageIndex];
      expect(visible.pageId, saved.pageId);
      expect((visible.backgroundImage as PdfEditorImage).pdfPage, 1);
      expect(await officePreviewRead(tester, fixture.revisionIds), before);
      expect(
        (await officePreviewRead(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        )).revision.revisionId,
        saved.latest.revision.revisionId,
      );
      expect(tester.takeException(), isNull);
    }),
    skip: !officePreviewPdfiumAvailable,
    variant: _platforms,
  );

  testWidgets(
    'cached Office original page becomes the matching baseline PDF ink page',
    (tester) => _withFixture(tester, (fixture) async {
      final original = await officePreviewRead(
        tester,
        () => fixture.documents.readLatest(fixture.note),
      );
      final before = await officePreviewRead(tester, fixture.revisionIds);
      final preview = _FixturePreview(fixture.directory);
      await fixture.mount(tester, preview: preview);
      final load = find.byKey(const ValueKey('office-original-preview-load'));
      await officePreviewUntil(
        tester,
        () =>
            load.evaluate().length == 1 &&
            tester.widget<ButtonStyleButton>(load).onPressed != null,
        'The imported document must offer a private original preview.',
      );
      await tester.ensureVisible(load);
      await tester.runAsync(() => tester.tap(load));
      await officePreviewUntil(
        tester,
        () => preview.pdfSha != null,
        'The synthetic converter must complete.',
      );
      await _expectPreview(tester, preview.pdfSha!, 1);
      expect(await officePreviewRead(tester, fixture.revisionIds), before);
      await _next(tester);
      await _expectPreview(tester, preview.pdfSha!, 2);

      final editor = await fixture.openInk(tester, fromPreviewPage: true);
      final variant = (await officePreviewRead(
        tester,
        () => fixture.documents.readPdfVariants(fixture.note, original),
      )).single;
      expect(variant.pdfSha256, preview.pdfSha);
      expect(variant.sourceRevisionId, original.revision.revisionId);
      expect(variant.revision.kind, EntityKind.attachment);
      expect(preview.calls, 1);
      final pages = editor.coreInfo.pages;
      expect(pages, hasLength(3));
      expect(pages.last.isEmpty, isTrue);
      expect(editor.currentPageIndex, 1);
      final visible = pages[editor.currentPageIndex];
      expect(visible.pageId, officePdfBaselinePageId(variant.bindingId, 1));
      expect((visible.backgroundImage as PdfEditorImage).pdfPage, 1);
      expect(
        (await officePreviewRead(
          tester,
          fixture.revisionIds,
        )).difference(before),
        {variant.revision.revisionId},
      );
      expect(
        await officePreviewRead(
          tester,
          () => fixture.repository.heads(variant.bindingId),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    }),
    skip: !officePreviewPdfiumAvailable,
    variant: _platforms,
  );

  testWidgets(
    'a foreign PDF background cannot replace the requested Office original page',
    (tester) => _withFixture(tester, (fixture) async {
      final saved = await officePreviewRead(
        tester,
        () => fixture.seedHistorical(foreignTarget: true),
      );
      final before = await officePreviewRead(tester, fixture.revisionIds);
      await fixture.mount(tester);
      await _expectPreview(tester, saved.latest.pdfSha256!, 1);
      await _selectEdition(tester, saved.historical.revision.revisionId);
      await _expectPreview(tester, saved.historical.pdfSha256!, 1);
      await _next(tester);
      await _expectPreview(tester, saved.historical.pdfSha256!, 2);
      await fixture.tapInk(tester);
      await officePreviewUntil(
        tester,
        () => !fixture.busy,
        'The rejected transition must finish without entering ink mode.',
      );
      await tester.pump();
      expect(find.byType(Editor), findsNothing);
      await _expectPreview(tester, saved.historical.pdfSha256!, 2);
      expect(await officePreviewRead(tester, fixture.revisionIds), before);
      expect(tester.takeException(), isNull);
    }),
    skip: !officePreviewPdfiumAvailable,
    variant: _platforms,
  );

  testWidgets(
    'choosing a conflicted Office ink branch still opens the requested original page',
    (tester) => _withFixture(tester, (fixture) async {
      final saved = await officePreviewRead(tester, fixture.seedHistorical);
      final binding = saved.historical.bindingId!;
      final selected = await officePreviewRead(tester, () async {
        final first = (await fixture.repository.heads(binding)).single;
        return fixture.repository.commit(
          entityId: binding,
          ownerNoteId: fixture.note.id,
          kind: EntityKind.ink,
          files: await fixture.repository.readFiles(first),
          parentRevisionIds: [],
        );
      });
      final before = await officePreviewRead(tester, fixture.revisionIds);
      expect(
        await officePreviewRead(
          tester,
          () => fixture.repository.heads(binding),
        ),
        hasLength(2),
      );
      await fixture.mount(tester);
      await _expectPreview(tester, saved.latest.pdfSha256!, 1);
      await _selectEdition(tester, saved.historical.revision.revisionId);
      await _expectPreview(tester, saved.historical.pdfSha256!, 1);
      await _next(tester);
      await _expectPreview(tester, saved.historical.pdfSha256!, 2);
      await fixture.tapInk(tester);
      final chooser = find.byKey(
        const ValueKey('office-open-annotation-conflict'),
      );
      await officePreviewUntil(
        tester,
        () => !fixture.busy && chooser.evaluate().length == 1,
        'A conflict must leave the original page visible and offer ink versions.',
      );
      await _expectPreview(tester, saved.historical.pdfSha256!, 2);
      await tester.ensureVisible(chooser);
      await tester.runAsync(() => tester.tap(chooser));
      final choice = find.byKey(
        ValueKey('office-annotation-${selected.revisionId}'),
      );
      await officePreviewUntil(
        tester,
        () => choice.evaluate().length == 1,
        'The exact PDF must offer both current ink branches.',
      );
      expect(find.byType(OfficeOriginalPreview), findsOneWidget);
      await tester.ensureVisible(choice);
      await tester.runAsync(() => tester.tap(choice));

      final editor = find.byType(Editor);
      await officePreviewUntil(
        tester,
        () =>
            !fixture.busy &&
            editor.evaluate().length == 1 &&
            tester.state<EditorState>(editor).coreInfo.pages.length > 2,
        'The selected branch must finish loading before checking its page.',
      );
      final state = tester.state<EditorState>(editor);
      final visible = state.coreInfo.pages[state.currentPageIndex];
      expect(visible.pageId, saved.pageId);
      expect(visible.strokes, hasLength(1));
      expect((visible.backgroundImage as PdfEditorImage).pdfPage, 1);
      expect(await officePreviewRead(tester, fixture.revisionIds), before);
      expect(tester.takeException(), isNull);
    }),
    skip: !officePreviewPdfiumAvailable,
    variant: _platforms,
  );
}

const _platforms = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.windows,
});

Future<void> _withFixture(
  WidgetTester tester,
  Future<void> Function(_Fixture) body,
) => withOfficePreviewPdfium(tester, () async {
  tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.android
      ? const Size(680, 920)
      : const Size(1060, 920);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final directory = await officePreviewRead(
    tester,
    () => Directory.systemTemp.createTemp('office-preview-to-ink-'),
  );
  NoteRepository? opened;
  try {
    final fixture = await officePreviewRead(tester, () async {
      await FileManager.init(
        documentsDirectory: p.join(directory.path, 'documents'),
        shouldWatchRootDirectory: false,
      );
      final repository = opened = await NoteRepository.open(
        Directory(p.join(directory.path, 'vault')),
        createFormatVersion: 2,
      );
      final documents = OfficeDocumentStore(repository);
      final note = await documents.importDocument(
        title: 'Office preview handoff',
        fileName: 'handoff.docx',
        bytes: annotationOfficeFile('Imported edition'),
      );
      return _Fixture(directory, repository, documents, note);
    });
    await body(fixture);
  } finally {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
      await officePreviewDocumentsClosed(tester);
    } finally {
      await officePreviewRead(tester, () async {
        await opened?.close();
        final system = await Directory.systemTemp.resolveSymbolicLinks();
        final owned = await directory.resolveSymbolicLinks();
        expect(p.dirname(owned), system);
        expect(p.basename(owned), startsWith('office-preview-to-ink-'));
        await Directory(owned).delete(recursive: true);
      });
    }
  }
});

Future<void> _expectPreview(WidgetTester tester, String sha, int page) async {
  final original = find.byType(OfficeOriginalPreview);
  final rendered = find.descendant(
    of: original,
    matching: find.byType(PdfPageView),
  );
  await officePreviewUntil(
    tester,
    () =>
        original.evaluate().length == 1 &&
        rendered.evaluate().length == 1 &&
        tester
            .widget<OfficeOriginalPreview>(original)
            .sourceKey
            .contains(sha) &&
        tester.widget<PdfPageView>(rendered).pageNumber == page,
    'The original preview must show page $page of the chosen edition.',
  );
}

Future<void> _selectEdition(WidgetTester tester, String revision) async {
  final selector = find.byKey(const ValueKey('office-edition-selector'));
  await officePreviewUntil(
    tester,
    () => tester.widget<DropdownButton<String>>(selector).onChanged != null,
    'The Office edition selector must be enabled.',
  );
  final select = tester.widget<DropdownButton<String>>(selector).onChanged!;
  await tester.runAsync(() async => select(revision));
}

Future<void> _next(WidgetTester tester) async {
  final next = find.byKey(const ValueKey('office-preview-next'));
  await tester.ensureVisible(next);
  await officePreviewUntil(
    tester,
    () =>
        next.hitTestable().evaluate().length == 1 &&
        tester.widget<IconButton>(next).onPressed != null,
    'The selected edition must finish opening before changing its page.',
  );
  await tester.tap(next);
}

class _Fixture {
  final Directory directory;
  final NoteRepository repository;
  final OfficeDocumentStore documents;
  final VaultNote note;
  var busy = true;

  new(this.directory, this.repository, this.documents, this.note);

  Future<Set<String>> revisionIds() async => {
    for (final revision in await repository.revisions()) revision.revisionId,
  };

  Future<({OfficeEdition historical, OfficeEdition latest, String pageId})>
  seedHistorical({bool foreignTarget = false}) async {
    final pdf = await officePreviewPdf(PdfColors.blue, second: PdfColors.green);
    final historical = await documents.commitEdited(
      await documents.beginEdit(note),
      originalBytes: annotationOfficeFile('Historical edition'),
      pdfBytes: pdf,
      pageCount: 2,
      engineVersion: 'preview-handoff-fixture',
    );
    final annotation = await OfficeAnnotationStore(repository)
        .open(note, historical);
    final source = await File(p.join(directory.path, 'historical.pdf'))
        .writeAsBytes(pdf, flush: true);
    final targetSource = foreignTarget
        ? await File(p.join(directory.path, 'foreign.pdf')).writeAsBytes(
            await officePreviewPdf(PdfColors.red, second: PdfColors.yellow),
            flush: true,
          )
        : source;
    final core = EditorCoreInfo(filePath: annotation.workingPath)
      ..nextImageId = 2;
    const size = Size(200, 300);
    EditorPage pdfPage(File file, int sourceIndex, int canvasIndex) =>
        EditorPage(
          size: size,
          backgroundImage: PdfEditorImage(
            id: sourceIndex,
            assetCache: core.assetCache,
            pdfBytes: null,
            pdfFile: file,
            pdfPage: sourceIndex,
            pageIndex: canvasIndex,
            pageSize: size,
            naturalSize: size,
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          ),
        );
    final ink = pdfPage(targetSource, 1, 2);
    try {
      core.pages.addAll([pdfPage(source, 0, 0), EditorPage(size: size), ink]);
      final pen = Pen.currentPen;
      pen.onDragStart(const Offset(24, 32), ink, 2, null);
      pen.onDragUpdate(const Offset(36, 44), null);
      ink.insertStroke(pen.onDragEnd()!);
      await annotation.saveSnapshot(core, 0);
    } finally {
      core.dispose();
    }
    final latest = await documents.commitEdited(
      await documents.beginEdit(note),
      originalBytes: annotationOfficeFile('Current edition'),
      pdfBytes: await officePreviewPdf(PdfColors.purple),
      pageCount: 1,
      engineVersion: 'preview-handoff-fixture',
    );
    return (historical: historical, latest: latest, pageId: ink.pageId);
  }

  Future<void> mount(WidgetTester tester, {OfficePreviewEngine? preview}) =>
      tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: OfficeWorkspace(
                repository: repository,
                note: note,
                engine: const _NoEditing(),
                previewEngine: preview,
                onBusyChanged: (value) => busy = value,
                onBack: () {},
              ),
            ),
          ),
        ),
      );

  Future<void> tapInk(WidgetTester tester) async {
    final mode = find.widgetWithText(SegmentedButton<bool>, 'PDF 필기');
    await officePreviewUntil(
      tester,
      () =>
          mode.evaluate().length == 1 &&
          tester.widget<SegmentedButton<bool>>(mode).onSelectionChanged != null,
      'The PDF ink segment must be enabled.',
    );
    final action = find.descendant(of: mode, matching: find.text('PDF 필기'));
    await tester.ensureVisible(action);
    await tester.runAsync(() => tester.tap(action));
  }

  Future<EditorState> openInk(
    WidgetTester tester, {
    bool fromPreviewPage = false,
  }) async {
    if (fromPreviewPage) {
      final action = find.byKey(const ValueKey('office-preview-annotate-page'));
      await officePreviewUntil(
        tester,
        () =>
            action.evaluate().length == 1 &&
            tester.widget<IconButton>(action).onPressed != null,
        'The preview page should have an enabled annotation action.',
      );
      await tester.ensureVisible(action);
      await tester.runAsync(() => tester.tap(action));
    } else {
      await tapInk(tester);
    }
    final editor = find.byType(Editor);
    final pdfs = PdfrxEntryFunctions.instance as OfficePreviewDocumentTracker;
    final inkPdfPages = find.descendant(
      of: editor,
      matching: find.byType(PdfPageView),
    );
    bool inkPdfLoaded() {
      if (!fromPreviewPage) return pdfs.filePaths.isNotEmpty;
      final state = tester.state<EditorState>(editor);
      final background = state.coreInfo.pages
          .elementAtOrNull(state.currentPageIndex)
          ?.backgroundImage;
      if (background is! PdfEditorImage) return false;
      final sourcePath = background.pdfFile?.path;
      return sourcePath != null &&
          p.basename(sourcePath) == 'preview.pdf' &&
          tester
              .widgetList<PdfPageView>(inkPdfPages)
              .any(
                (page) =>
                    page.document?.sourceName == sourcePath &&
                    page.pageNumber == background.pdfPage + 1,
              );
    }

    await officePreviewUntil(
      tester,
      () =>
          !busy &&
          editor.evaluate().length == 1 &&
          tester.state<EditorState>(editor).coreInfo.pages.isNotEmpty &&
          inkPdfLoaded() &&
          pdfs.pendingOpens == 0,
      'The real PDF ink editor must finish loading before checking its page.',
    );
    await tester.pump();
    return tester.state<EditorState>(editor);
  }
}

class _FixturePreview extends OfficePreviewEngine {
  final Directory directory;
  String? pdfSha;
  var calls = 0;

  new(this.directory);

  @override
  Future<OfficePreviewResult> preview({
    required String sourcePath,
    required String sessionId,
  }) async {
    calls++;
    final bytes = await officePreviewPdf(PdfColors.red, second: PdfColors.blue);
    final file = await File(p.join(directory.path, 'private-$sessionId.pdf'))
        .writeAsBytes(bytes, flush: true);
    final source = await File(sourcePath).readAsBytes();
    return OfficePreviewResult(
      pdfPath: file.path,
      pdfSha256: pdfSha = sha256.convert(bytes).toString(),
      pageCount: 2,
      sourceSha256: sha256.convert(source).toString(),
      engineVersion: 'preview-handoff-fixture',
    );
  }
}

class _NoEditing extends AndroidOfficeEngine {
  const new();

  @override
  Future<AndroidOfficeCapabilities> capabilities() async =>
      const AndroidOfficeCapabilities(
        available: false,
        engineVersion: 'preview-handoff-fixture',
        editableFormats: [],
      );
}
