import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' show PdfColor, PdfColors, PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_page_link.dart';
import 'package:saber/data/office/pptx_annotation_carry.dart';
import 'package:saber/data/office/pptx_shape_text.dart';
import 'package:saber/data/office/pptx_slide_identity.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';
import 'office_original_preview_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  for (final changedSlide in [false, true]) {
    testWidgets(
      changedSlide
          ? 'a changed slide keeps its annotation in the prior edition'
          : 'annotation follows a reordered slide while historical ink is preserved',
      (tester) => withOfficePreviewPdfium(tester, () async {
        await officePreviewRead(tester, () async {
          final dir = await Directory.systemTemp.createTemp('pptx-carry-test-');
          await FileManager.init(
            documentsDirectory: p.join(dir.path, 'documents'),
            shouldWatchRootDirectory: false,
          );
          final repository = await NoteRepository.open(
            Directory(p.join(dir.path, 'vault')),
            createFormatVersion: 2,
          );
          try {
            final documents = OfficeDocumentStore(repository);
            final note = await documents.importDocument(
              title: 'Presentation',
              fileName: 'slides.pptx',
              bytes: _package('original'),
            );
            Future<OfficeEdition> save(String name, Uint8List pdf) async =>
                documents.commitEdited(
                  await documents.beginEdit(note),
                  originalBytes: _package(name),
                  pdfBytes: pdf,
                  engineVersion: 'test',
                  pageCount: 2,
                );
            final oldPdf = changedSlide
                ? await _widePdf([PdfColors.red, PdfColors.blue])
                : await officePreviewPdf(PdfColors.red, second: PdfColors.blue);
            final previous = await save('before', oldPdf);
            final old = await OfficeAnnotationStore(repository)
                .open(note, previous);
            final core = EditorCoreInfo(filePath: old.workingPath)
              ..nextImageId = 1;
            final natural = Size(changedSlide ? 2000 : 200, 300);
            final size = Size(1000, 1000 * natural.height / natural.width);
            final annotated = EditorPage(
              size: size,
              backgroundImage: PdfEditorImage(
                id: 0,
                assetCache: core.assetCache,
                pdfBytes: oldPdf,
                pdfFile: null,
                pdfPage: 1,
                pageIndex: 1,
                pageSize: size,
                naturalSize: natural,
                onMoveImage: null,
                onDeleteImage: null,
                onMiscChange: null,
              ),
            );
            try {
              core.pages.addAll([EditorPage(size: size), annotated]);
              final pen = Pen.currentPen;
              pen.onDragStart(const Offset(24, 32), annotated, 1, null);
              pen.onDragUpdate(const Offset(36, 44), null);
              annotated.insertStroke(pen.onDragEnd()!);
              await old.saveSnapshot(core, 1);
            } finally {
              core.dispose();
            }
            final oldRecord = old.revision!;
            final originalInk = await repository.readFiles(oldRecord);
            final newPdf = changedSlide
                ? await _widePdf([PdfColors.green, PdfColors.red])
                : await officePreviewPdf(PdfColors.blue, second: PdfColors.red);
            final current = await save('after', newPdf);
            final result = await carryPreviousPptxAnnotations(
              repository: repository,
              note: note,
              edition: current,
              isCurrent: () => true,
              slideIdentity: _ReorderedSlides(
                previous.originalSha256,
                current.originalSha256,
              ),
            );
            expect(result.copiedPages, changedSlide ? 0 : 1);
            expect(result.skippedPages, changedSlide ? 1 : 0);
            expect(await repository.readFiles(oldRecord), originalInk);
            final target = await OfficeAnnotationStore(repository)
                .open(note, current);
            if (changedSlide) {
              expect(target.revision, isNull);
            } else {
              final loaded = await target.load();
              try {
                expect(loaded.pages, hasLength(3));
                expect(
                  loaded.pages.first.pageId,
                  officePdfBaselinePageId(current.bindingId!, 0),
                );
                expect(loaded.pages.first.strokes, hasLength(1));
                expect(loaded.pages[1].strokes, isEmpty);
                final background =
                    loaded.pages.first.backgroundImage as PdfEditorImage;
                expect(background.pdfPage, 0);
                expect(await background.pdfFile!.readAsBytes(), newPdf);
              } finally {
                loaded.dispose();
              }
              await expectLater(
                carryPreviousPptxAnnotations(
                  repository: repository,
                  note: note,
                  edition: current,
                  isCurrent: () => true,
                ),
                throwsStateError,
              );
              expect(
                (await repository.heads(current.bindingId!)).single.revisionId,
                target.revision!.revisionId,
              );
            }
          } finally {
            await repository.close();
            final owned = await dir.resolveSymbolicLinks();
            expect(
              p.dirname(owned),
              await Directory.systemTemp.resolveSymbolicLinks(),
            );
            expect(p.basename(owned), startsWith('pptx-carry-test-'));
            await Directory(owned).delete(recursive: true);
          }
        });
      }),
      skip: !officePreviewPdfiumAvailable,
    );
  }

  final native = Platform.environment['PIV_CARRY_TEST_DLL'];
  final fixture = Platform.environment['PIV_CARRY_TEST_IMPRESS_FIXTURE'];
  testWidgets(
    'Office button opens the reordered Impress PDF with the copied ink',
    (tester) => withOfficePreviewPdfium(tester, () async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1050, 950);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final dir = await officePreviewRead(
        tester,
        () => Directory.systemTemp.createTemp('pptx-carry-ui-test-'),
      );
      NoteRepository? opened;
      try {
        final (repository, note, latest, previousInk) = await officePreviewRead(
          tester,
          () async {
            await FileManager.init(
              documentsDirectory: p.join(dir.path, 'documents'),
              shouldWatchRootDirectory: false,
            );
            final repository = opened = await NoteRepository.open(
              Directory(p.join(dir.path, 'vault')),
              createFormatVersion: 2,
            );
            final documents = OfficeDocumentStore(repository);
            Future<Uint8List> read(String name) =>
                File(p.join(fixture!, name)).readAsBytes();
            final original = await read('original.pptx');
            final note = await documents.importDocument(
              title: 'Impress reorder',
              fileName: 'slides.pptx',
              bytes: original,
            );
            final previous = await documents.commitEdited(
              await documents.beginEdit(note),
              originalBytes: original,
              pdfBytes: await read('original.pdf'),
              engineVersion: 'Impress fixture',
              pageCount: 3,
            );
            final originalPdf = previous.pdfBytes!;
            final document = await PdfDocument.openData(
              originalPdf,
              useProgressiveLoading: false,
            );
            final Size natural;
            try {
              natural = document.pages[1].size;
            } finally {
              await document.dispose();
            }
            final annotation = await OfficeAnnotationStore(repository)
                .open(note, previous);
            final core = EditorCoreInfo(filePath: annotation.workingPath)
              ..nextImageId = 1;
            final size = Size(1000, 1000 * natural.height / natural.width);
            final page = EditorPage(
              size: size,
              backgroundImage: PdfEditorImage(
                id: 0,
                assetCache: core.assetCache,
                pdfBytes: originalPdf,
                pdfFile: null,
                pdfPage: 1,
                pageIndex: 0,
                pageSize: size,
                naturalSize: natural,
                onMoveImage: null,
                onDeleteImage: null,
                onMiscChange: null,
              ),
            );
            try {
              core.pages.add(page);
              final pen = Pen.currentPen;
              pen.onDragStart(const Offset(36, 42), page, 0, null);
              pen.onDragUpdate(const Offset(48, 54), null);
              page.insertStroke(pen.onDragEnd()!);
              await annotation.saveSnapshot(core, 0);
            } finally {
              core.dispose();
            }
            final latest = await documents.commitEdited(
              await documents.beginEdit(note),
              originalBytes: await read('moved.pptx'),
              pdfBytes: await read('moved.pdf'),
              engineVersion: 'Impress fixture',
              pageCount: 3,
            );
            return (repository, note, latest, annotation.revision!);
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: OfficeWorkspace(
                repository: repository,
                note: note,
                pptxShapeText: PptxShapeTextEngine(libraryPath: native),
                pptxSlideIdentity: PptxSlideIdentityEngine(libraryPath: native),
                onBack: () {},
              ),
            ),
          ),
        );
        final carry = find.byKey(
          const ValueKey('office-carry-previous-pptx-ink'),
        );
        final align = find.byKey(
          const ValueKey('office-align-pptx-shape-paragraph'),
        );
        await officePreviewUntil(
          tester,
          () =>
              align.evaluate().length == 1 &&
              tester.widget<OutlinedButton>(align).onPressed != null,
          'Windows original mode must offer paragraph alignment.',
        );
        await tester.ensureVisible(align);
        await tester.runAsync(() => tester.tap(align));
        await officePreviewUntil(
          tester,
          () => find.text('PPTX 도형 문단 정렬').evaluate().length == 1,
          'The Windows entry must open the shared paragraph dialog.',
        );
        await tester.tap(find.widgetWithText(TextButton, '취소'));
        await officePreviewUntil(
          tester,
          () =>
              carry.evaluate().length == 1 &&
              tester.widget<OutlinedButton>(carry).onPressed != null,
          'The latest original must offer annotation carry.',
        );
        await tester.ensureVisible(carry);
        await tester.runAsync(() => tester.tap(carry));
        final editor = find.byType(Editor);
        try {
          await officePreviewUntil(
            tester,
            () =>
                editor.evaluate().length == 1 &&
                tester.state<EditorState>(editor).coreInfo.pages.length == 4,
            'The copied PDF and its ink must open.',
          );
        } on TestFailure catch (failure) {
          fail(
            '$failure Office messages ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).whereType<String>().join(' / ')}',
          );
        }
        final pages = tester.state<EditorState>(editor).coreInfo.pages;
        expect(
          pages.first.pageId,
          officePdfBaselinePageId(latest.bindingId!, 0),
        );
        expect(pages.first.strokes, hasLength(1));
        expect(pages.skip(1).every((page) => page.strokes.isEmpty), isTrue);
        expect(find.text('1쪽의 필기를 가져왔습니다.'), findsOneWidget);
        expect(
          await officePreviewRead(
            tester,
            () => repository
                .heads(previousInk.entityId)
                .then((heads) => heads.single.revisionId),
          ),
          previousInk.revisionId,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 6));
        await officePreviewDocumentsClosed(tester);
        await officePreviewRead(tester, () async {
          await opened?.close();
          final owned = await dir.resolveSymbolicLinks();
          expect(
            p.dirname(owned),
            await Directory.systemTemp.resolveSymbolicLinks(),
          );
          expect(p.basename(owned), startsWith('pptx-carry-ui-test-'));
          await Directory(owned).delete(recursive: true);
        });
      }
    }),
    skip: !officePreviewPdfiumAvailable || native == null || fixture == null,
  );
}

class _ReorderedSlides extends PptxSlideIdentityEngine {
  new(this.before, this.after);

  final String before;
  final String after;

  @override
  Future<PptxSlideIdentityMatch> match({
    required String previousPath,
    required String previousSha256,
    required String currentPath,
    required String currentSha256,
  }) async {
    expect(previousSha256, before);
    expect(currentSha256, after);
    expect(File(previousPath).existsSync(), isTrue);
    expect(File(currentPath).existsSync(), isTrue);
    return PptxSlideIdentityMatch(
      previousToCurrent: [1, 0],
      currentSlideCount: 2,
    );
  }
}

Future<Uint8List> _widePdf(List<PdfColor> colors) {
  final document = pw.Document();
  for (final color in colors) {
    document.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(2000, 300),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Container(
          width: 2000,
          height: 300,
          alignment: pw.Alignment.centerRight,
          child: pw.Container(width: 80, height: 70, color: color),
        ),
      ),
    );
  }
  return document.save();
}

Uint8List _package(String label) => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
      ..addFile(
        ArchiveFile.string(
          'ppt/presentation.xml',
          '<document>$label</document>',
        ),
      ),
  ),
);
