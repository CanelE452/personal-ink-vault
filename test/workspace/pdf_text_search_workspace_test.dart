import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/pdf_import_state.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_navigation.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../office/office_original_preview_test.dart'
    show
        OfficePreviewDocumentTracker,
        officePreviewDocumentsClosed,
        officePreviewRead,
        officePreviewUntil;
import '../utils/test_mock_channel_handlers.dart';

Future<({VaultNote note, NoteLink secondPage})> _savedPdf(
  NoteRepository repo,
) async {
  final document = pw.Document();
  for (final text in ['Original first page', 'Searchable original needle']) {
    document.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(200, 300),
        build: (_) => pw.Text(text),
      ),
    );
  }
  final store = WorkspaceStore(repo);
  final note = await store.createWithSource(
    'Study PDF',
    fileName: 'study.pdf',
    bytes: await document.save(),
    documentKind: VaultDocumentKind.pdf,
  );
  final session = await store.open(note);
  final prepared = await PdfImportPreparation.prepare(session);
  expect(prepared.message, isNull);
  final marker = prepared.marker!.encode();
  final source = File(prepared.path!);
  final core = EditorCoreInfo(filePath: '/test-search')..nextImageId = 2;
  const size = Size(200, 300);
  try {
    for (var i = 0; i < 2; i++) {
      core.pages.add(
        EditorPage(
          size: size,
          backgroundImage: PdfEditorImage(
            id: i,
            assetCache: core.assetCache,
            pdfBytes: null,
            pdfFile: source,
            pdfPage: i,
            pageIndex: i,
            pageSize: size,
            naturalSize: size,
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          ),
        ),
      );
    }
    final second = core.pages[1];
    final pen = Pen.currentPen;
    pen.onDragStart(const Offset(24, 32), second, 1, null);
    pen.onDragUpdate(const Offset(36, 44), null);
    second.insertStroke(pen.onDragEnd()!);
    final link = NoteLink(note.id, second.pageId);
    Future<void> save() async {
      final files = await SaberInkAdapter.capture(core, 0);
      await session.saveInk({...files, PdfImportMarker.fileName: marker});
    }

    await save();
    core.pages.insert(1, EditorPage(size: size));
    core.pages[2].updatePageIndex(2);
    await save();
    return (note: note, secondPage: link);
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
  final nativePath = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  final pdfiumPath = Platform.environment['PIV_PDF_ANCHOR_TEST_PDFIUM'];

  testWidgets(
    'Study searches original PDF text and reopens its saved ink page',
    (tester) async {
      final compact = defaultTargetPlatform == TargetPlatform.android;
      tester.view.physicalSize = compact
          ? const Size(360, 920)
          : const Size(1060, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await officePreviewRead(
        tester,
        () => Directory.systemTemp.createTemp('pdf-text-search-study-'),
      );
      final previousPdfium = Pdfrx.pdfiumModulePath;
      final previousBackend = PdfrxEntryFunctions.instance;
      final documents = OfficePreviewDocumentTracker(previousBackend);
      addTearDown(() async {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          if (identical(PdfrxEntryFunctions.instance, documents)) {
            await officePreviewDocumentsClosed(tester);
          }
        } finally {
          PdfrxEntryFunctions.instance = previousBackend;
          Pdfrx.pdfiumModulePath = previousPdfium;
          await officePreviewRead(tester, () async {
            final owned = await directory.resolveSymbolicLinks();
            final system = await Directory.systemTemp.resolveSymbolicLinks();
            expect(p.dirname(owned), system);
            expect(p.basename(owned), startsWith('pdf-text-search-study-'));
            await Directory(owned).delete(recursive: true);
          });
        }
      });
      await officePreviewRead(tester, () async {
        Pdfrx.pdfiumModulePath = File(pdfiumPath!).absolute.path;
        await pdfrxInitialize(tmpPath: directory.path);
        await FileManager.init(
          documentsDirectory: p.join(directory.path, 'documents'),
          shouldWatchRootDirectory: false,
        );
      });
      PdfrxEntryFunctions.instance = documents;
      final repo = await officePreviewRead(
        tester,
        () => NoteRepository.open(
          Directory(p.join(directory.path, 'vault')),
          createFormatVersion: 2,
        ),
      );
      addTearDown(() => officePreviewRead(tester, repo.close));
      final fixture = await officePreviewRead(tester, () => _savedPdf(repo));
      const crossLinkLabel = 'Open the cached annotated page';
      final linkSource = await officePreviewRead(
        tester,
        () => WorkspaceStore(repo).createMarkdown(
          'PDF links',
          utf8.encode('[$crossLinkLabel](${fixture.secondPage})'),
        ),
      );
      final controller = WorkspaceController(
        repo,
        native: InkVaultNative.open(libraryPath: nativePath),
        directoryProvider: () async =>
            Directory(p.join(directory.path, 'support')),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await officePreviewRead(tester, controller.flush);
        controller.dispose();
      });
      await officePreviewRead(tester, () => controller.openNote(fixture.note));
      final session = controller.activeSession!;
      final inkHead = session.inkParents.single;
      Future<Set<String>> revisions() async => {
        for (final row in await repo.revisions()) row.revisionId,
      };
      final before = await officePreviewRead(tester, revisions);
      expect(controller.pdfImportError, isNull);
      expect(controller.pendingPdfPath, isNull);
      final loaded = await officePreviewRead(
        tester,
        () => controller.loadInk(session: session),
      );
      try {
        expect(loaded.pages[2].pageId, fixture.secondPage.pageId);
        expect(loaded.pages[2].strokes, hasLength(1));
        final access = controller.pdfTextSearch(session, loaded);
        expect(access, isNotNull);
        final noMatch = await officePreviewRead(
          tester,
          () => access!.search('no such document text', () => true),
        );
        expect(noMatch?.hasText, isTrue);
        expect(noMatch?.hits, isEmpty);
        final match = await officePreviewRead(
          tester,
          () => access!.search('original needle', () => true),
        );
        expect(match?.hits, hasLength(1));
        final hit = match!.hits.single;
        expect(hit.pageNumber, 2);
        expect(hit.pageId, fixture.secondPage.pageId);
        expect(await officePreviewRead(tester, revisions), before);
        debugPrint(
          'PDF_SEARCH154_DATA_PASS $defaultTargetPlatform '
          'noMatch=true page=2 uuidMatch=true strokes=1 revisionsUnchanged=true',
        );
      } finally {
        loaded.dispose();
      }
      try {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(home: StudyWorkspace(controller: controller)),
          ),
        );
        final editor = find.byType(Editor);
        EditorState state() => tester.state<EditorState>(editor);
        try {
          await officePreviewUntil(
            tester,
            () =>
                editor.evaluate().length == 1 &&
                state().coreInfo.pages.length >= 3 &&
                state().coreInfo.pages[2].pageId == fixture.secondPage.pageId &&
                !controller.inkBusy,
            'The pre-saved PDF and ink must be loaded before searching.',
          );
        } on TestFailure {
          final count = editor.evaluate().length;
          final errors = tester
              .widgetList<Text>(find.byType(Text))
              .map((widget) => widget.data ?? '')
              .where(
                (text) => text.contains('열 수 없습니다') || text.contains('실패'),
              );
          fail(
            'PDF editor initialization: count=$count '
            'pages=${count == 1 ? state().coreInfo.pages.length : null} '
            'inkBusy=${controller.inkBusy} pendingPdf=${controller.pendingPdfPath != null} '
            'importError=${controller.pdfImportError} visibleErrors=${errors.toList()}',
          );
        }
        Future<void> revealFirstPage() async {
          await tester.pump();
          final first = state().coreInfo.pages.first;
          var revealed = false;
          await officePreviewUntil(tester, () {
            revealed =
                revealed ||
                state().revealPage(
                  first.pageId,
                  background: first.backgroundImage!,
                );
            return revealed && state().currentPageIndex == 0;
          }, 'The first original page must be visible before navigation.');
        }

        await revealFirstPage();
        expect(state().coreInfo.pages[1].backgroundImage, isNull);
        final saved = state().coreInfo.pages[2];
        expect(saved.pageId, fixture.secondPage.pageId);
        expect((saved.backgroundImage as PdfEditorImage).pdfPage, 1);
        expect(saved.strokes, hasLength(1));

        final search = find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'PDF 본문 검색',
        );
        expect(search, findsOneWidget);
        expect(search.hitTestable(), findsOneWidget);
        expect(tester.widget<IconButton>(search).onPressed, isNotNull);
        await tester.tap(search);
        await tester.pumpAndSettle();
        final query = find.byKey(const ValueKey('pdf-text-search-query'));
        Future<void> submit(String text) async {
          await tester.enterText(query, text);
          await tester.pump();
          await tester.runAsync(() => tester.tap(find.text('검색')));
        }

        await submit('no such document text');
        await officePreviewUntil(
          tester,
          () => find.text('일치하는 문구가 없습니다.').evaluate().length == 1,
          'A text-bearing PDF with no match must report no results.',
        );
        expect(state().currentPageIndex, 0);
        await submit('original needle');
        final hit = find.byKey(const ValueKey('pdf-text-search-hit-2'));
        await officePreviewUntil(
          tester,
          () => hit.evaluate().length == 1,
          'The match must identify original PDF page 2.',
        );
        expect(find.text('원본 2페이지'), findsOneWidget);
        await tester.runAsync(() => tester.tap(hit));

        Future<void> waitForOriginalPage(String reason) => officePreviewUntil(
          tester,
          () =>
              controller.navigation.current.pageId ==
                  fixture.secondPage.pageId &&
              editor.evaluate().length == 1 &&
              state().currentPageIndex == 2,
          reason,
        );
        await waitForOriginalPage(
          'Search must reveal the ink after the inserted page.',
        );
        expect(state().coreInfo.pages[2].strokes, hasLength(1));
        expect(controller.activeSession!.inkParents.single, inkHead);
        expect(await officePreviewRead(tester, revisions), before);
        debugPrint(
          'PDF_SEARCH154_UI_PASS $defaultTargetPlatform '
          'noMatch=true page=2 uuidMatch=true strokes=1 revisionsUnchanged=true',
        );
        final workspaceProgress = find.byType(LinearProgressIndicator);
        final navigationFile = File(
          p.join(repo.root.path, '.workspace', 'navigation.json'),
        );
        await officePreviewUntil(
          tester,
          () => workspaceProgress.evaluate().isEmpty,
          'The workspace must finish saving navigation.',
        );
        final persisted = await officePreviewRead(
          tester,
          () => WorkspaceNavigation.load(navigationFile),
        );
        final oldLink = NoteLink.parse(fixture.secondPage.toString());
        expect(oldLink?.noteId, fixture.note.id);
        expect(oldLink?.pageId, controller.navigation.current.pageId);
        expect(oldLink?.pageId, persisted.current.pageId);

        final linkButton = compact
            ? find.byKey(const ValueKey('workspace-more-actions'))
            : find.byTooltip('노트 링크 열기');
        final linkField = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        Future<void> waitForLinkedPage(NoteLink link, int expectedIndex) async {
          try {
            await officePreviewUntil(
              tester,
              () =>
                  workspaceProgress.evaluate().isEmpty &&
                  linkField.evaluate().isEmpty &&
                  controller.activeSession?.note.id == link.noteId &&
                  controller.navigation.current.pageId == link.pageId &&
                  editor.evaluate().length == 1 &&
                  state().coreInfo.pages.length > expectedIndex &&
                  state().coreInfo.pages[expectedIndex].pageId == link.pageId &&
                  state().currentPageIndex == expectedIndex,
              'The explicit link must show its saved page in the target document.',
            );
          } on TestFailure {
            final count = editor.evaluate().length;
            final current = count == 1 ? state() : null;
            final messages = tester
                .widgetList<Text>(find.byType(Text))
                .map((widget) => widget.data ?? '')
                .where(
                  (text) =>
                      text.contains('열 수 없습니다') ||
                      text.contains('찾을 수 없습니다') ||
                      text.contains('실패'),
                );
            fail(
              'Explicit link navigation: expected=$expectedIndex '
              'editorCount=$count pages=${current?.coreInfo.pages.length} '
              'initial=${current?.coreInfo.initialPageIndex} visible=${current?.currentPageIndex} '
              'noteMatches=${controller.activeSession?.note.id == link.noteId} '
              'navMatches=${controller.navigation.current.pageId == link.pageId} '
              'progress=${workspaceProgress.evaluate().length} '
              'dialogFields=${linkField.evaluate().length} inkBusy=${controller.inkBusy} '
              'error=${controller.error} importError=${controller.pdfImportError} '
              'visibleErrors=${messages.toList()}',
            );
          }
          final afterLink = await officePreviewRead(
            tester,
            () => WorkspaceNavigation.load(navigationFile),
          );
          expect(afterLink.current.noteId, link.noteId);
          expect(afterLink.current.pageId, link.pageId);
        }

        Future<void> openExplicitPage(NoteLink link, int expectedIndex) async {
          await officePreviewUntil(
            tester,
            () =>
                workspaceProgress.evaluate().isEmpty &&
                linkButton.hitTestable().evaluate().length == 1,
            'The page link button must be reachable.',
          );
          await tester.runAsync(() => tester.tap(linkButton));
          if (compact) {
            final item = find.text('노트 링크 열기');
            await officePreviewUntil(
              tester,
              () => item.hitTestable().evaluate().length == 1,
              'The page link action must be reachable in the compact menu.',
            );
            await tester.runAsync(() => tester.tap(item));
          }
          await officePreviewUntil(
            tester,
            () => linkField.hitTestable().evaluate().length == 1,
            'The page link dialog must expose its input.',
          );
          await tester.enterText(linkField, link.toString());
          await tester.pump();
          await tester.runAsync(() => tester.tap(find.text('확인')));
          await waitForLinkedPage(link, expectedIndex);
        }

        await revealFirstPage();
        await openExplicitPage(oldLink!, 2);
        expect(state().coreInfo.pages[2].strokes, hasLength(1));
        final inserted = state().coreInfo.pages[1];
        await openExplicitPage(NoteLink(fixture.note.id, inserted.pageId), 1);
        expect(state().coreInfo.pages[1].backgroundImage, isNull);
        expect(state().coreInfo.pages[1].strokes, isEmpty);
        expect(controller.activeSession!.inkParents.single, inkHead);
        expect(await officePreviewRead(tester, revisions), before);
        debugPrint(
          'PAGE_UUID_LINK_PASS $defaultTargetPlatform '
          'annotatedIndex=2 insertedBlankIndex=1 persisted=true revisionsUnchanged=true',
        );

        final cachedPdfPath = state().coreInfo.filePath;
        await officePreviewRead(tester, () => controller.openNote(linkSource));
        final markdownLink = find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              (widget.data ?? widget.textSpan?.toPlainText()) == crossLinkLabel,
        );
        final editableLink = find.descendant(
          of: markdownLink,
          matching: find.byType(EditableText),
        );
        await officePreviewUntil(
          tester,
          () =>
              controller.activeSession?.note.id == linkSource.id &&
              editor.evaluate().isEmpty &&
              editableLink.hitTestable().evaluate().length == 1,
          'The source Markdown preview must render its clickable page link.',
        );
        expect(CanvasTransformCache.get(cachedPdfPath), isNotNull);
        final render = tester
            .state<EditableTextState>(editableLink)
            .renderEditable;
        final glyph = render
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 1),
            )
            .first;
        await tester.runAsync(
          () => tester.tapAt(render.localToGlobal(glyph.toRect().center)),
        );
        await waitForLinkedPage(fixture.secondPage, 2);
        if (defaultTargetPlatform == TargetPlatform.android) {
          expect(
            tester
                .widget<NavigationBar>(find.byType(NavigationBar))
                .selectedIndex,
            0,
          );
        }
        expect(state().coreInfo.pages[2].strokes, hasLength(1));
        expect(controller.activeSession!.inkParents.single, inkHead);
        expect(await officePreviewRead(tester, revisions), before);
        debugPrint(
          'PAGE_UUID_LINK_CROSS_PASS $defaultTargetPlatform '
          'cachedPdf=true annotatedIndex=2 persisted=true revisionsUnchanged=true',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 6));
      }
    },
    skip:
        !Platform.isWindows ||
        nativePath == null ||
        !File(nativePath).existsSync() ||
        pdfiumPath == null ||
        !File(pdfiumPath).existsSync(),
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
