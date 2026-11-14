import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_view_state.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';
import 'annotation_store_test.dart' show annotationOfficeFile;
import 'office_original_preview_test.dart'
    show
        OfficePreviewDocumentTracker,
        officePreviewDocumentsClosed,
        officePreviewPdfiumAvailable,
        officePreviewRead,
        officePreviewUntil,
        withOfficePreviewPdfium;

class _FixtureOfficeEngine extends AndroidOfficeEngine {
  const new();

  @override
  Future<AndroidOfficeCapabilities> capabilities() async =>
      const AndroidOfficeCapabilities(
        available: false,
        engineVersion: 'office-search-fixture',
        editableFormats: [],
      );
}

const _needle = 'bound office needle';

Future<
  ({
    VaultNote note,
    String sourceRevisionId,
    String bindingId,
    String? firstId,
    String? hitId,
  })
>
_seedOfficePdf(
  NoteRepository repository,
  Directory directory, {
  required bool hasInk,
}) async {
  final document = pw.Document();
  for (final text in ['Office cover page', 'The $_needle is on this page']) {
    document.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(200, 300),
        build: (_) => pw.Text(text),
      ),
    );
  }
  final pdf = await document.save();
  final original = annotationOfficeFile('Office search fixture');
  final documents = OfficeDocumentStore(repository);
  final note = await documents.importDocument(
    title: 'Office search fixture',
    fileName: 'search.docx',
    bytes: original,
  );
  final edit = await documents.beginEdit(note);
  Future<void> remember(String sourceId, String bindingId, String? pageId) =>
      OfficeViewStore(repository, note.id).save(
        OfficeViewState(
          vaultId: repository.vaultId,
          noteId: note.id,
          sourceRevisionId: sourceId,
          bindingId: bindingId,
          pdfMode: true,
          pageId: pageId,
        ),
      );
  if (!hasInk) {
    final preview = await documents.commitDerivedPdf(
      edit,
      pdfBytes: pdf,
      pageCount: 2,
    );
    await remember(preview.sourceRevisionId, preview.bindingId, null);
    return (
      note: note,
      sourceRevisionId: preview.sourceRevisionId,
      bindingId: preview.bindingId,
      firstId: null,
      hitId: null,
    );
  }
  final edition = await documents.commitEdited(
    edit,
    originalBytes: original,
    pdfBytes: pdf,
    engineVersion: 'office-search-fixture',
    pageCount: 2,
  );
  final annotation = await OfficeAnnotationStore(repository)
      .open(note, edition);
  final source = await File(p.join(directory.path, 'fixture.pdf'))
      .writeAsBytes(pdf, flush: true);
  final core = EditorCoreInfo(filePath: annotation.workingPath)
    ..nextImageId = 2;
  const size = Size(200, 300);
  EditorPage pdfPage(int sourceIndex, int canvasIndex) => EditorPage(
    size: size,
    backgroundImage: PdfEditorImage(
      id: sourceIndex,
      assetCache: core.assetCache,
      pdfBytes: null,
      pdfFile: source,
      pdfPage: sourceIndex,
      pageIndex: canvasIndex,
      pageSize: size,
      naturalSize: size,
      onMoveImage: null,
      onDeleteImage: null,
      onMiscChange: null,
    ),
  );
  try {
    final first = pdfPage(0, 0);
    final hit = pdfPage(1, 2);
    core.pages.addAll([first, EditorPage(size: size), hit]);
    final pen = Pen.currentPen;
    pen.onDragStart(const Offset(24, 32), hit, 2, null);
    pen.onDragUpdate(const Offset(36, 44), null);
    hit.insertStroke(pen.onDragEnd()!);
    await annotation.saveSnapshot(core, 0);
    await remember(
      edition.revision.revisionId,
      annotation.bindingId,
      first.pageId,
    );
    return (
      note: note,
      sourceRevisionId: edition.revision.revisionId,
      bindingId: annotation.bindingId,
      firstId: first.pageId,
      hitId: hit.pageId,
    );
  } finally {
    core.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  testWidgets(
    'Office PDF search opens the saved ink page without changing revisions',
    (tester) => withOfficePreviewPdfium(tester, () async {
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.android
          ? const Size(600, 920)
          : const Size(1060, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await officePreviewRead(
        tester,
        () => Directory.systemTemp.createTemp('office-pdf-search-'),
      );
      NoteRepository? opened;
      Future<void> closeEditor() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 6));
        await officePreviewDocumentsClosed(tester);
      }

      try {
        final repository = await officePreviewRead(tester, () async {
          await FileManager.init(
            documentsDirectory: p.join(directory.path, 'documents'),
            shouldWatchRootDirectory: false,
          );
          return opened = await NoteRepository.open(
            Directory(p.join(directory.path, 'vault')),
            createFormatVersion: 2,
          );
        });
        Future<Set<String>> revisionIds() async => {
          for (final revision in await repository.revisions())
            revision.revisionId,
        };
        for (final hasInk in [true, false]) {
          final fixture = await officePreviewRead(
            tester,
            () => _seedOfficePdf(repository, directory, hasInk: hasInk),
          );
          final hitIndex = hasInk ? 2 : 1;
          final expectedStrokes = hasInk ? 1 : 0;
          final pdfs =
              PdfrxEntryFunctions.instance as OfficePreviewDocumentTracker;
          final previousOpens = pdfs.filePaths.length;
          final before = await officePreviewRead(tester, revisionIds);
          Future<List<RevisionRecord>> heads() =>
              repository.heads(fixture.bindingId);
          expect(
            await officePreviewRead(tester, heads),
            hasLength(expectedStrokes),
          );
          final views = OfficeViewStore(repository, fixture.note.id);
          var busy = true;
          await tester.pumpWidget(
            TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: OfficeWorkspace(
                    repository: repository,
                    note: fixture.note,
                    engine: const _FixtureOfficeEngine(),
                    onBack: () {},
                    onBusyChanged: (value) => busy = value,
                  ),
                ),
              ),
            ),
          );
          final editor = find.byType(Editor);
          EditorState state() => tester.state<EditorState>(editor);
          await officePreviewUntil(
            tester,
            () =>
                !busy &&
                editor.evaluate().length == 1 &&
                state().coreInfo.pages.length > hitIndex &&
                pdfs.filePaths.length > previousOpens &&
                !pdfs.allClosed &&
                pdfs.pendingOpens == 0,
            'The Office PDF and its annotation must load in the actual editor.',
          );
          final firstPage = state().coreInfo.pages.first;
          final hitPage = state().coreInfo.pages[hitIndex];
          if (hasInk) {
            expect(firstPage.pageId, fixture.firstId);
            expect(hitPage.pageId, fixture.hitId);
            expect(state().coreInfo.pages[1].backgroundImage, isNull);
          }
          expect((firstPage.backgroundImage as PdfEditorImage).pdfPage, 0);
          expect((hitPage.backgroundImage as PdfEditorImage).pdfPage, 1);
          expect(hitPage.strokes, hasLength(expectedStrokes));
          await officePreviewUntil(
            tester,
            () =>
                state().revealPage(
                  firstPage.pageId,
                  background: firstPage.backgroundImage,
                ) &&
                state().currentPageIndex == 0,
            'The first Office page must be visible before searching.',
          );

          final search = find.byKey(const ValueKey('office-pdf-text-search'));
          expect(search.hitTestable(), findsOneWidget);
          await tester.tap(search);
          final query = find.byKey(const ValueKey('pdf-text-search-query'));
          await officePreviewUntil(
            tester,
            () => query.hitTestable().evaluate().length == 1,
            'The Office search action must open the PDF query field.',
          );
          Future<void> submit(String text) async {
            await tester.enterText(query, text);
            await tester.pump();
            await tester.runAsync(() => tester.tap(find.text('검색')));
          }

          await submit('no matching text');
          await officePreviewUntil(
            tester,
            () => find.text('일치하는 문구가 없습니다.').evaluate().length == 1,
            'A text-bearing Office PDF with no match must report no results.',
          );
          expect(state().currentPageIndex, 0);
          await submit(_needle);
          final hit = find.byKey(const ValueKey('pdf-text-search-hit-2'));
          await officePreviewUntil(
            tester,
            () => hit.hitTestable().evaluate().length == 1,
            'PDFium must find the phrase on the original second page.',
          );
          expect(find.text('원본 2페이지'), findsOneWidget);
          await tester.runAsync(() => tester.tap(hit));
          await officePreviewUntil(
            tester,
            () =>
                query.evaluate().isEmpty &&
                state().currentPageIndex == hitIndex &&
                state().coreInfo.pages[hitIndex].pageId == hitPage.pageId,
            'The result must reveal the bound original second page.',
          );
          final persisted = await officePreviewRead(tester, () async {
            for (var i = 0; i < 60; i++) {
              final view = await views.load();
              if (view?.pageId == hitPage.pageId) return view;
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            return views.load();
          });
          expect(persisted?.pdfMode, isTrue);
          expect(persisted?.sourceRevisionId, fixture.sourceRevisionId);
          expect(persisted?.bindingId, fixture.bindingId);
          expect(
            persisted?.pageId,
            hitPage.pageId,
            reason:
                find.textContaining('이전 보기 상태를 저장하지 못했습니다').evaluate().isEmpty
                ? 'The view store did not report a write error.'
                : 'The Office workspace reported a view-store write error.',
          );
          expect(
            state().coreInfo.pages[hitIndex].strokes,
            hasLength(expectedStrokes),
          );
          expect(
            await officePreviewRead(tester, heads),
            hasLength(expectedStrokes),
          );
          expect(await officePreviewRead(tester, revisionIds), before);
          expect(tester.takeException(), isNull);
          debugPrint(
            'OFFICE_PDF_SEARCH157_PASS $defaultTargetPlatform hasInk=$hasInk hitIndex=$hitIndex',
          );
          await closeEditor();
        }
      } finally {
        try {
          await closeEditor();
        } finally {
          await officePreviewRead(tester, () async {
            await opened?.close();
            final owned = await directory.resolveSymbolicLinks();
            final system = await Directory.systemTemp.resolveSymbolicLinks();
            expect(p.dirname(owned), system);
            expect(p.basename(owned), startsWith('office-pdf-search-'));
            await Directory(owned).delete(recursive: true);
          });
        }
      }
    }),
    skip: !officePreviewPdfiumAvailable,
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
