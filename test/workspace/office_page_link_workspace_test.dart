import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_view_state.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../office/annotation_store_test.dart' show annotationOfficeFile;
import '../office/office_original_preview_test.dart'
    show
        officePreviewDocumentsClosed,
        officePreviewPdf,
        officePreviewPdfiumAvailable,
        officePreviewRead,
        officePreviewUntil,
        withOfficePreviewPdfium;
import '../utils/test_mock_channel_handlers.dart';

const _referenceText = 'Open the annotated original';
const _wrongBindingText = 'Open an unavailable edition and PDF combination';

Future<({VaultNote office, VaultNote markdown, OfficePageTarget target})>
_seedOfficeLink(NoteRepository repository, Directory directory) async {
  final documents = OfficeDocumentStore(repository);
  final office = await documents.importDocument(
    title: 'Office lecture',
    fileName: 'lecture.docx',
    bytes: annotationOfficeFile('Imported edition'),
  );
  final edit = await documents.beginEdit(office);
  final imported = await documents.readLatest(office);
  final pdf = await officePreviewPdf(PdfColors.blue, second: PdfColors.green);
  await documents.commitDerivedPdf(
    edit,
    pdfBytes: await officePreviewPdf(PdfColors.red),
    pageCount: 1,
  );
  final alternate = await documents.commitDerivedPdf(
    edit,
    pdfBytes: pdf,
    pageCount: 2,
  );
  final annotation = await OfficeAnnotationStore(repository)
      .open(office, imported, preview: alternate);
  final pdfFile = await File(p.join(directory.path, 'alternate.pdf'))
      .writeAsBytes(pdf, flush: true);
  final core = EditorCoreInfo(filePath: annotation.workingPath)
    ..nextImageId = 2;
  const size = Size(200, 300);
  EditorPage page(int number) => EditorPage(
    size: size,
    backgroundImage: PdfEditorImage(
      id: number,
      assetCache: core.assetCache,
      pdfBytes: null,
      pdfFile: pdfFile,
      pdfPage: number,
      pageIndex: number,
      pageSize: size,
      naturalSize: size,
      onMoveImage: null,
      onDeleteImage: null,
      onMiscChange: null,
    ),
  );

  final linked = page(1);
  final target = (
    sourceRevisionId: imported.revision.revisionId,
    pdfBindingId: alternate.bindingId,
    pageId: linked.pageId,
  );
  try {
    core.pages.addAll([page(0), linked]);
    final pen = Pen.currentPen;
    pen.onDragStart(const Offset(24, 32), linked, 1, null);
    pen.onDragUpdate(const Offset(36, 44), null);
    linked.insertStroke(pen.onDragEnd()!);
    await annotation.saveSnapshot(core, 0);
    core.pages.insert(1, EditorPage(size: size));
    linked.updatePageIndex(2);
    await annotation.saveSnapshot(core, 0);
  } finally {
    core.dispose();
  }

  final latest = await documents.commitEdited(
    edit,
    originalBytes: annotationOfficeFile('Current edition'),
    pdfBytes: await officePreviewPdf(PdfColors.purple),
    pageCount: 1,
    engineVersion: 'office-page-link-fixture',
  );
  await OfficeViewStore(repository, office.id).save(
    OfficeViewState(
      vaultId: repository.vaultId,
      noteId: office.id,
      sourceRevisionId: latest.revision.revisionId,
      bindingId: latest.bindingId,
      pdfMode: true,
      pageId: null,
    ),
  );

  final store = WorkspaceStore(repository);
  final markdown = await store.create(
    'Lecture summary',
    documentKind: VaultDocumentKind.markdown,
  );
  final markdownSession = await store.open(markdown);
  final wrongBinding = NoteLink.officePage(office.id, (
    sourceRevisionId: target.sourceRevisionId,
    pdfBindingId: latest.bindingId!,
    pageId: target.pageId,
  ));
  final link = NoteLink.officePage(office.id, target);
  await markdownSession.saveMarkdown(
    '[$_wrongBindingText]($wrongBinding)\n\n[$_referenceText]($link)',
  );
  return (office: office, markdown: markdown, target: target);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  testWidgets(
    'Office page links use the exact saved edition, PDF and retained ink page',
    (tester) => withOfficePreviewPdfium(tester, () async {
      final phone = defaultTargetPlatform == TargetPlatform.android;
      tester.view.physicalSize = Size(phone ? 540 : 1540, 1040);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await officePreviewRead(
        tester,
        () => Directory.systemTemp.createTemp('office-page-link-'),
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final copied = <String>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      NoteRepository? opened;
      WorkspaceController? controller;
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
        final fixture = await officePreviewRead(
          tester,
          () => _seedOfficeLink(repository, directory),
        );
        final workspace = controller = WorkspaceController(
          repository,
          directoryProvider: () async =>
              Directory(p.join(directory.path, 'support')),
        );
        await officePreviewRead(
          tester,
          () => workspace.openNote(fixture.markdown),
        );
        final view = OfficeViewStore(repository, fixture.office.id);
        final before = await officePreviewRead(tester, view.load);
        expect(
          before?.sourceRevisionId,
          isNot(fixture.target.sourceRevisionId),
        );
        final beforeRevisions = await officePreviewRead(
          tester,
          repository.revisions,
        );

        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(home: StudyWorkspace(controller: workspace)),
          ),
        );
        Finder markdownLink(String label) => find.descendant(
          of: find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText &&
                (widget.data ?? widget.textSpan?.toPlainText()) == label,
          ),
          matching: find.byType(EditableText),
        );

        Future<void> tapMarkdownLink(String label) async {
          final link = markdownLink(label);
          await officePreviewUntil(
            tester,
            () => link.hitTestable().evaluate().length == 1,
            'The saved Markdown reference must be visible in the workspace.',
          );
          final render = tester.state<EditableTextState>(link).renderEditable;
          final glyph = render
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 1),
              )
              .first;
          await tester.runAsync(
            () => tester.tapAt(render.localToGlobal(glyph.toRect().center)),
          );
        }

        final valid = NoteLink.officePage(fixture.office.id, fixture.target);
        Future<void> pasteLink(String link) async {
          final button = find.byTooltip('노트 링크 열기');
          await officePreviewUntil(
            tester,
            () =>
                button.hitTestable().evaluate().length == 1 &&
                find.byType(LinearProgressIndicator).evaluate().isEmpty,
            'The page link action must be reachable.',
          );
          await tester.runAsync(() => tester.tap(button));
          final dialog = find.byType(AlertDialog);
          final field = find.descendant(
            of: dialog,
            matching: find.byType(TextField),
          );
          await officePreviewUntil(
            tester,
            () => field.hitTestable().evaluate().length == 1,
            'The link dialog must expose its input.',
          );
          expect(find.text('inkvault 링크 열기'), findsOneWidget);
          await tester.enterText(field, link);
          await tester.pump();
          final confirm = find.descendant(
            of: dialog,
            matching: find.widgetWithText(FilledButton, '확인'),
          );
          await tester.runAsync(() => tester.tap(confirm));
        }

        final editor = find.byType(Editor);
        if (phone) {
          await tapMarkdownLink(_wrongBindingText);
          await officePreviewUntil(
            tester,
            () => find.byType(SnackBar).evaluate().isNotEmpty,
            'A PDF from the current edition cannot resolve the historical link.',
          );
          expect(workspace.activeSession?.note.id, fixture.markdown.id);
          expect(editor, findsNothing);
          expect(
            (await officePreviewRead(tester, view.load))?.sourceRevisionId,
            before?.sourceRevisionId,
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(seconds: 5));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(SnackBar), findsNothing);
          await tapMarkdownLink(_referenceText);
        } else {
          await pasteLink(valid.toString());
        }

        EditorState state() => tester.state<EditorState>(editor);
        bool destinationVisible() =>
            workspace.activeSession?.note.id == fixture.office.id &&
            editor.evaluate().length == 1 &&
            state().currentPageIndex == 2 &&
            state().coreInfo.pages.elementAtOrNull(2)?.pageId ==
                fixture.target.pageId &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty;
        List<String> errors() => tester
            .widgetList<Text>(find.byType(Text))
            .map((widget) => widget.data ?? '')
            .where(
              (text) => text.contains('페이지 링크') || text.contains('Exception'),
            )
            .toList();

        Future<void> waitForDestination(String action) async {
          try {
            await officePreviewUntil(
              tester,
              () => destinationVisible() || errors().isNotEmpty,
              action,
            );
          } on TestFailure {
            // Report the route state with the assertion below.
          }
          final current = editor.evaluate().length == 1 ? state() : null;
          expect(
            destinationVisible(),
            isTrue,
            reason:
                '$action Office note open=${workspace.activeSession?.note.id == fixture.office.id} '
                'page=${current?.currentPageIndex} count=${current?.coreInfo.pages.length} '
                'inkBusy=${workspace.inkBusy} dialog=${find.byType(AlertDialog).evaluate().length} '
                'visibleErrors=${errors()}',
          );
        }

        await waitForDestination(
          'The link must reveal the original second PDF page at ink index 2.',
        );
        final pages = state().coreInfo.pages;
        final linked = pages[state().currentPageIndex];
        expect(pages[1].backgroundImage, isNull);
        expect(linked.pageId, fixture.target.pageId);
        expect((linked.backgroundImage as PdfEditorImage).pdfPage, 1);
        expect(linked.strokes, hasLength(1));
        String? selected(String key) => tester
            .widget<DropdownButton<String>>(find.byKey(ValueKey(key)))
            .value;
        expect(
          selected('office-edition-selector'),
          fixture.target.sourceRevisionId,
        );
        expect(
          selected('office-pdf-variant-selector'),
          fixture.target.pdfBindingId,
        );
        await tester.runAsync(() => tester.tap(find.byTooltip('현재 페이지 링크 복사')));
        await officePreviewUntil(
          tester,
          () => copied.isNotEmpty,
          'The Office link must be copied.',
        );
        final parsed = NoteLink.parse(copied.single);
        expect(parsed?.noteId, fixture.office.id);
        expect(parsed?.officePageTarget, fixture.target);

        final originalEditor = state();
        final first = pages.first;
        await officePreviewUntil(
          tester,
          () =>
              originalEditor.revealPage(
                first.pageId,
                background: first.backgroundImage,
              ) &&
              originalEditor.currentPageIndex == 0,
          'The active editor must move away from the copied page.',
        );
        await pasteLink(copied.single);
        await waitForDestination(
          'Pasting the same link must return to the copied page.',
        );
        expect(state(), same(originalEditor));
        expect(state().coreInfo.pages[state().currentPageIndex], same(linked));
        expect(
          selected('office-edition-selector'),
          fixture.target.sourceRevisionId,
        );
        expect(
          selected('office-pdf-variant-selector'),
          fixture.target.pdfBindingId,
        );

        await pasteLink(
          NoteLink.officePage(fixture.office.id, (
            sourceRevisionId: fixture.target.sourceRevisionId,
            pdfBindingId: fixture.target.pdfBindingId,
            pageId: newId(),
          )).toString(),
        );
        await officePreviewUntil(
          tester,
          () => find.byType(SnackBar).evaluate().isNotEmpty,
          'A missing page must report the broken link.',
        );
        expect(workspace.activeSession?.note.id, fixture.office.id);
        expect(
          identical(state().coreInfo.pages[state().currentPageIndex], linked),
          isTrue,
        );
        expect(
          selected('office-edition-selector'),
          fixture.target.sourceRevisionId,
        );
        expect(
          selected('office-pdf-variant-selector'),
          fixture.target.pdfBindingId,
        );
        final afterRevisions = await officePreviewRead(
          tester,
          repository.revisions,
        );
        expect(
          afterRevisions.map((item) => item.revisionId).toSet(),
          beforeRevisions.map((item) => item.revisionId).toSet(),
        );
        expect(tester.takeException(), isNull);
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 6));
        try {
          await officePreviewDocumentsClosed(tester);
        } finally {
          await officePreviewRead(tester, () async {
            controller?.dispose();
            await opened?.close();
            final path = await directory.resolveSymbolicLinks();
            final temp = await Directory.systemTemp.resolveSymbolicLinks();
            expect(p.dirname(path), temp);
            expect(p.basename(path), startsWith('office-page-link-'));
            final owned = Directory(path);
            for (var attempt = 0; ; attempt++) {
              try {
                await owned.delete(recursive: true);
                break;
              } on PathAccessException catch (error) {
                if (error.osError?.errorCode != 32 || attempt == 9) rethrow;
                await Future<void>.delayed(const Duration(milliseconds: 30));
              }
            }
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
