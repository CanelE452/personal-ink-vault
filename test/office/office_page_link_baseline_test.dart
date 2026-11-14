import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_view_state.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';
import 'annotation_store_test.dart' show annotationOfficeFile;
import 'office_original_preview_test.dart'
    show
        officePreviewPdf,
        officePreviewPdfiumAvailable,
        officePreviewRead,
        officePreviewUntil,
        withOfficePreviewPdfium;

class _UnavailableOffice extends AndroidOfficeEngine {
  const new();

  @override
  Future<AndroidOfficeCapabilities> capabilities() async =>
      const AndroidOfficeCapabilities(
        available: false,
        engineVersion: 'office-page-link-baseline',
        editableFormats: [],
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  testWidgets(
    'Office page links check actual PDF pages before the first ink revision',
    (tester) => withOfficePreviewPdfium(tester, () async {
      tester.view.physicalSize = const Size(1060, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final directory = await officePreviewRead(
        tester,
        () => Directory.systemTemp.createTemp('office-page-link-baseline-'),
      );
      NoteRepository? opened;
      addTearDown(() async {
        await opened?.close();
        final root = await Directory.systemTemp.resolveSymbolicLinks();
        final owned = await directory.resolveSymbolicLinks();
        expect(p.isWithin(root, owned), isTrue);
        expect(p.basename(owned), startsWith('office-page-link-baseline-'));
        await Directory(owned).delete(recursive: true);
      });

      final (repository, note, preview) = await officePreviewRead(
        tester,
        () async {
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
            title: 'Two PDF pages',
            fileName: 'baseline.docx',
            bytes: annotationOfficeFile('baseline'),
          );
          final preview = await documents.commitDerivedPdf(
            await documents.beginEdit(note),
            pdfBytes: await officePreviewPdf(
              PdfColors.red,
              second: PdfColors.blue,
            ),
            pageCount: 2,
          );
          await OfficeViewStore(repository, note.id).save(
            OfficeViewState(
              vaultId: repository.vaultId,
              noteId: note.id,
              sourceRevisionId: preview.sourceRevisionId,
              bindingId: preview.bindingId,
              pdfMode: true,
              pageId: null,
            ),
          );
          return (repository, note, preview);
        },
      );
      expect(preview.pageCount, isNull);
      Future<Set<String>> revisionIds() async => {
        for (final revision in await repository.revisions())
          revision.revisionId,
      };
      final before = await officePreviewRead(tester, revisionIds);

      try {
        final workspace = GlobalKey<OfficeWorkspaceState>();
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: OfficeWorkspace(
                  key: workspace,
                  repository: repository,
                  note: note,
                  engine: const _UnavailableOffice(),
                  onBack: () {},
                ),
              ),
            ),
          ),
        );
        final editor = find.byType(Editor);
        await officePreviewUntil(
          tester,
          () => workspace.currentState?.currentPageLink != null,
          'The editor must load the saved derived PDF before linking.',
        );
        final pages = tester.state<EditorState>(editor).coreInfo.pages;
        expect(
          pages.where((page) => page.backgroundImage != null),
          hasLength(2),
        );
        final baselineId = tester
            .widget<Editor>(editor)
            .initialPdfBaselinePageId!;
        final secondPageId = pages[1].pageId;
        expect(secondPageId, baselineId(1));

        Future<OfficePageLinkRequest> prepare(String pageId) =>
            officePreviewRead(
              tester,
              () => OfficeWorkspace.preparePageLink(
                repository: repository,
                noteId: note.id,
                target: (
                  sourceRevisionId: preview.sourceRevisionId,
                  pdfBindingId: preview.bindingId,
                  pageId: pageId,
                ),
              ),
            );
        final request = await prepare(secondPageId);
        expect(request.target.pageId, secondPageId);
        expect(request.target.pdfBindingId, preview.bindingId);
        await expectLater(prepare('not-a-uuid'), throwsFormatException);
        await expectLater(prepare(baselineId(2)), throwsFormatException);
        expect(
          await officePreviewRead(
            tester,
            () => repository.heads(preview.bindingId),
          ),
          isEmpty,
        );
        expect(await officePreviewRead(tester, revisionIds), before);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 6));
      }
    }),
    skip: !officePreviewPdfiumAvailable,
  );
}
