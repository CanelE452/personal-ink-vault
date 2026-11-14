import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_bookmarks.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../office/office_original_preview_test.dart'
    show
        OfficePreviewDocumentTracker,
        officePreviewDocumentsClosed,
        officePreviewPdf,
        officePreviewRead,
        officePreviewUntil;
import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  final nativePath = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  final pdfiumPath = Platform.environment['PIV_PDF_ANCHOR_TEST_PDFIUM'];

  testWidgets(
    'Study previews the nested source PDF page and opens its original ink page',
    (tester) async {
      tester.view.physicalSize = const Size(1060, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await officePreviewRead(
        tester,
        () => Directory.systemTemp.createTemp('obsidian-pdf-embed-study-'),
      );
      final oldPdfium = Pdfrx.pdfiumModulePath;
      final oldBackend = PdfrxEntryFunctions.instance;
      final documents = OfficePreviewDocumentTracker(oldBackend);
      addTearDown(() async {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          if (identical(PdfrxEntryFunctions.instance, documents)) {
            await officePreviewDocumentsClosed(tester);
          }
        } finally {
          PdfrxEntryFunctions.instance = oldBackend;
          Pdfrx.pdfiumModulePath = oldPdfium;
        }
        await officePreviewRead(tester, () async {
          final owned = await directory.resolveSymbolicLinks();
          final system = await Directory.systemTemp.resolveSymbolicLinks();
          expect(p.dirname(owned), system);
          expect(p.basename(owned), startsWith('obsidian-pdf-embed-study-'));
          await Directory(owned).delete(recursive: true);
        });
      });
      await officePreviewRead(tester, () async {
        Pdfrx.pdfiumModulePath = File(pdfiumPath!).absolute.path;
        await pdfrxInitialize(tmpPath: directory.path);
      });
      PdfrxEntryFunctions.instance = documents;
      final (repo, controller) = await officePreviewRead(tester, () async {
        await FileManager.init(
          documentsDirectory: p.join(directory.path, '한글 문서'),
          shouldWatchRootDirectory: false,
        );
        final repo = await NoteRepository.open(
          Directory(p.join(directory.path, 'vault')),
          createFormatVersion: 2,
        );
        final controller = WorkspaceController(
          repo,
          native: InkVaultNative.open(libraryPath: nativePath),
          directoryProvider: () async =>
              Directory(p.join(directory.path, 'support')),
        );
        return (repo, controller);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await officePreviewRead(tester, () async {
          await controller.flush();
          controller.dispose();
          await repo.close();
        });
      });

      Future<(VaultNote, VaultNote, VaultNote)> createFixture() async {
        final folders = LibraryStore(repo);
        final hostFolder = await folders.createFolder('HostFolder');
        final sourceFolder = await folders.createFolder('Source');
        final store = WorkspaceStore(repo);
        final host = await store.createMarkdown(
          'Host',
          utf8.encode('![[Source/Embed]]'),
          folderId: hostFolder.id,
        );
        final embedded = await store.createMarkdown(
          'Embed',
          utf8.encode('![[./Handout.pdf#page=2&height=320|Source page]]'),
          folderId: sourceFolder.id,
        );
        final sourcePdf = await store.createWithSource(
          'Handout.pdf',
          fileName: 'Handout.pdf',
          bytes: await officePreviewPdf(PdfColors.red, second: PdfColors.blue),
          folderId: sourceFolder.id,
          documentKind: VaultDocumentKind.pdf,
          fromObsidian: true,
        );
        await store.createWithSource(
          'Handout.pdf',
          fileName: 'Handout.pdf',
          bytes: await officePreviewPdf(
            PdfColors.green,
            second: PdfColors.green,
          ),
          folderId: hostFolder.id,
          documentKind: VaultDocumentKind.pdf,
          fromObsidian: true,
        );
        await controller.refresh();
        await controller.openNote(host);
        return (host, embedded, sourcePdf);
      }

      final (host, embedded, sourcePdf) = (await tester.runAsync(
        () => createFixture().timeout(const Duration(seconds: 12)),
      ))!;
      Future<Set<String>> revisionIds() async => {
        for (final revision in await repo.revisions()) revision.revisionId,
      };
      const href = 'inkwiki:.%2FHandout.pdf#page%3D2%26height%3D320';
      final link = controller.knowledge!.resolveWikiLink(
        href,
        fromNoteId: embedded.id,
      );
      expect(link?.noteId, sourcePdf.id);
      expect(link?.attachmentName, 'Handout.pdf');
      expect(link?.anchor, 'page=2&height=320');
      final before = await officePreviewRead(tester, revisionIds);

      try {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(home: StudyWorkspace(controller: controller)),
          ),
        );
        final loadFromOriginalScope = tester
            .widget<MarkdownEditor>(find.byType(MarkdownEditor))
            .vaultEmbeds!
            .loadPdf!;
        final uncancelled = ValueNotifier(false);
        final cancelled = ValueNotifier(true);
        addTearDown(uncancelled.dispose);
        addTearDown(cancelled.dispose);
        final preview = find.byWidgetPredicate(
          (widget) => widget is Image && widget.semanticLabel == 'Source page',
        );
        await officePreviewUntil(
          tester,
          () => preview.evaluate().length == 1,
          'The nested PDF embed must show a raster rather than only a text link.',
        );
        final provider = tester.widget<Image>(preview).image;
        final memory =
            (provider is ResizeImage ? provider.imageProvider : provider)
                as MemoryImage;
        final decoded = image.decodePng(memory.bytes)!;
        final center = decoded.getPixel(
          decoded.width ~/ 2,
          decoded.height ~/ 2,
        );
        expect(center.b, greaterThan(center.r + 80));
        expect(center.b, greaterThan(center.g + 60));
        expect(tester.getSize(preview).height, 320);
        expect(controller.activeSession?.note.id, host.id);
        expect(await officePreviewRead(tester, revisionIds), before);
        await officePreviewDocumentsClosed(tester);
        expect(
          await officePreviewRead(
            tester,
            () => loadFromOriginalScope(href, embedded.id, 1, uncancelled),
          ),
          isNull,
        );
        expect(
          await officePreviewRead(
            tester,
            () => loadFromOriginalScope(href, embedded.id, 2, cancelled),
          ),
          isNull,
          reason: 'A closed preview may not load even in the same workspace.',
        );

        final action = find.widgetWithText(TextButton, 'PDF 필기 열기 · 2쪽');
        Future<void> openFromPreview() async {
          await officePreviewUntil(
            tester,
            () => action.evaluate().length == 1,
            'The preview must expose the source PDF ink action.',
          );
          await tester.ensureVisible(action);
          await tester.pump();
          expect(
            action.hitTestable(),
            findsOneWidget,
            reason: 'The source PDF action must receive the tap.',
          );
          await tester.runAsync(() => tester.tap(action));
        }

        final editor = find.byType(Editor);
        EditorState editorState() => tester.state<EditorState>(editor);
        await openFromPreview();
        try {
          await officePreviewUntil(
            tester,
            () =>
                controller.activeSession?.note.id == sourcePdf.id &&
                !controller.dirty &&
                editor.evaluate().length == 1 &&
                editorState().coreInfo.pages.any(
                  (page) => page.backgroundImage is PdfEditorImage,
                ) &&
                controller.navigation.current.pageId != null,
            'The linked source PDF and its initial ink page must open.',
          );
        } on TestFailure {
          final active = controller.activeSession;
          final activeNote = active?.note.id;
          final location = controller.navigation.current;
          final editorCount = editor.evaluate().length;
          final current = editorCount == 1 ? editorState() : null;
          final pages = current?.coreInfo.pages;
          final pdfPages = [
            if (pages != null)
              for (final page in pages)
                if (page.backgroundImage case final PdfEditorImage pdf)
                  pdf.pdfPage + 1,
          ];
          final messages = tester
              .widgetList<Text>(find.byType(Text))
              .map((widget) => widget.data ?? '')
              .where(
                (message) =>
                    message.contains('열 수 없습니다') ||
                    message.contains('찾을 수 없') ||
                    message.contains('바뀌었습니다') ||
                    message.contains('실패'),
              )
              .toList();
          fail(
            'The linked source PDF and its initial ink page must open. '
            'activeHost=${activeNote == host.id} '
            'activeSource=${activeNote == sourcePdf.id} '
            'dirty=${controller.dirty} inkBusy=${controller.inkBusy} '
            'inkHeads=${active?.inkParents.length} '
            'pendingImport=${controller.pendingPdfPath != null} '
            'editorCount=$editorCount mounted=${current?.mounted} '
            'pageCount=${pages?.length} pdfPages=$pdfPages '
            'navSource=${location.noteId == sourcePdf.id} '
            'navMarkdown=${location.markdown} navPage=${location.pageId} '
            'error=${controller.error} importError=${controller.pdfImportError} '
            'visibleErrors=$messages',
          );
        }
        final originalPage = editorState().coreInfo.pages.singleWhere((page) {
          final background = page.backgroundImage;
          return background is PdfEditorImage && background.pdfPage == 1;
        });
        expect(controller.navigation.current.pageId, originalPage.pageId);
        expect(editorState().currentPageIndex, 1);
        expect(
          await officePreviewRead(
            tester,
            () => loadFromOriginalScope(href, embedded.id, 2, uncancelled),
          ),
          isNull,
          reason:
              'A disposed preview scope may no longer retrieve vault bytes.',
        );
        final previousInk = controller.activeSession!.inkParents.single;
        editorState().insertPageAfter(0);
        expect(editorState().coreInfo.pages[1].backgroundImage, isNull);
        expect(editorState().coreInfo.pages[2].pageId, originalPage.pageId);
        await officePreviewRead(tester, editorState().saveToFile);
        expect(controller.activeSession!.inkParents.single, isNot(previousInk));

        await officePreviewRead(tester, () => controller.openNote(host));
        await openFromPreview();
        await officePreviewUntil(
          tester,
          () =>
              controller.activeSession?.note.id == sourcePdf.id &&
              controller.navigation.current.pageId == originalPage.pageId &&
              editor.evaluate().length == 1 &&
              editorState().currentPageIndex == 2,
          'The action must return to original PDF page 2 past the inserted page.',
        );
        expect(editorState().coreInfo.pages[2].pageId, originalPage.pageId);

        final bookmark = await officePreviewRead(tester, () async {
          final bookmark = await WorkspaceBookmarkStore(repo).add(
            WorkspaceBookmarkSpec(
              kind: WorkspaceBookmarkKind.note,
              title: '원본 PDF 2쪽 북마크',
              target: NoteLink(sourcePdf.id).toString(),
              pdfPageNumber: 2,
            ),
          );
          await controller.openNote(host);
          return bookmark;
        });
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('workspace-bookmarks')));
        final bookmarkRow = find.byKey(
          ValueKey(
            'workspace-bookmark-open-${bookmark.id}-${bookmark.revisionId}',
          ),
        );
        await officePreviewUntil(
          tester,
          () => bookmarkRow.evaluate().length == 1,
          'The original page bookmark must be listed.',
        );
        await tester.runAsync(() => tester.tap(bookmarkRow));
        await officePreviewUntil(
          tester,
          () =>
              controller.activeSession?.note.id == sourcePdf.id &&
              controller.navigation.current.pageId == originalPage.pageId &&
              editor.evaluate().length == 1 &&
              editorState().currentPageIndex == 2,
          'The bookmark must reach original PDF page 2 past the inserted page.',
        );

        final current = editorState();
        final core = current.coreInfo;
        final savedPageIndex = core.initialPageIndex ?? 0;
        final readingPage = core.pages.indexWhere(
          (page) =>
              page.pageId != core.pages[savedPageIndex].pageId &&
              page.backgroundImage is PdfEditorImage,
        );
        expect(readingPage, isNonNegative);
        final page = core.pages[readingPage];
        final pageId = page.pageId;
        final inkHead = controller.activeSession!.inkParents.single;
        expect(
          current.revealPage(pageId, background: page.backgroundImage!),
          isTrue,
        );
        expect(current.currentPageIndex, readingPage);
        expect(controller.dirty, isFalse);

        final switcher = find.byKey(const ValueKey('workspace-tab-switcher'));
        await officePreviewUntil(
          tester,
          () => tester.widget<PopupMenuButton<String>>(switcher).enabled,
          'The tabs menu must be enabled after opening the bookmark.',
        );
        await tester.tap(switcher);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => tester.tap(
            find.byKey(ValueKey('workspace-tab-switcher-item-${host.id}')),
          ),
        );
        final pdfTab = find.byKey(ValueKey('document-tab-${sourcePdf.id}'));
        await officePreviewUntil(
          tester,
          () =>
              controller.activeSession?.note.id == host.id &&
              tester.widget<InkWell>(pdfTab).onTap != null,
          'The Markdown tab must open before returning to the PDF.',
        );
        expect(
          controller.navigation.tabs
              .singleWhere((tab) => tab.noteId == sourcePdf.id)
              .location
              ?.pageId,
          pageId,
        );
        CanvasTransformCache.clear();
        await tester.runAsync(() => tester.tap(pdfTab));
        await officePreviewUntil(
          tester,
          () =>
              controller.activeSession?.note.id == sourcePdf.id &&
              editor.evaluate().length == 1 &&
              editorState().coreInfo.pages.any(
                (page) => page.backgroundImage is PdfEditorImage,
              ),
          'The PDF tab must reopen and load its page images.',
        );
        expect(controller.navigation.current.pageId, pageId);
        expect(editorState().coreInfo.initialPageIndex, readingPage);
        expect(editorState().currentPageIndex, readingPage);
        expect(controller.activeSession!.inkParents.single, inkHead);
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
