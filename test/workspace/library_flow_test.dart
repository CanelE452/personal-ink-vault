import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:pdfrx/pdfrx.dart' show PdfDocument;
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/pdf_note_original.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/pdf_import_state.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_bookmarks.dart';
import 'package:saber/data/vault/workspace_markdown_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_workspace.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../office/office_original_preview_test.dart'
    show
        officePreviewPdf,
        officePreviewPdfiumAvailable,
        officePreviewUntil,
        withOfficePreviewPdfium;
import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late WorkspaceController controller;
  late bool controllerDisposed;
  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('library-flow-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    await controller.refresh();
    controllerDisposed = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    if (!controllerDisposed) {
      await controller.flush();
      controller.dispose();
      await controller.repository.close();
    }
    for (var attempt = 0; ; attempt++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on PathAccessException catch (error) {
        if (!controllerDisposed ||
            !Platform.isWindows ||
            error.osError?.errorCode != 32 ||
            attempt == 19) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
    }
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<T> readWhilePumping<T>(
    WidgetTester tester,
    Future<T> Function() read,
  ) async {
    var done = false;
    T? value;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      read()
          .timeout(const Duration(seconds: 15))
          .then(
            (result) {
              value = result;
              done = true;
            },
            onError: (Object error, StackTrace stack) {
              failure = error;
              trace = stack;
              done = true;
            },
          );
    });
    for (var i = 0; i < 80 && !done; i++) {
      await drain(tester);
    }
    expect(done, isTrue);
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return value as T;
  }

  Future<void> mount(
    WidgetTester tester, {
    OfficePreviewEngine? office,
    ThumbnailCache Function(Directory) thumbnailCache = ThumbnailCache.new,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: StudyWorkspace(
            controller: controller,
            officePreviewEngine: office,
            thumbnailCacheFactory: thumbnailCache,
          ),
        ),
      ),
    );
    await drain(tester);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  Future<void> closeOfficeFlow(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    await readWhilePumping(tester, () async {
      await controller.flush();
      controller.dispose();
      await controller.repository.close();
    });
    controllerDisposed = true;
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets(
    'the Android Office picker reads a document only after mode selection',
    (tester) => withOfficePreviewPdfium(tester, () async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const channel = MethodChannel('personal_ink_vault/office_source');
      const id = '00000000-0000-4000-8000-000000000021';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final previousPaths = PathProviderPlatform.instance;
      final cache = Directory(p.join(temp.path, 'picker-cache'));
      PathProviderPlatform.instance = _LibraryTestPaths(
        temp.path,
        cache: cache.path,
      );
      final input = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: '선택한 발표',
      );
      final staged = File(
        p.join(
          cache.path,
          'office-picker',
          'office-00000000-0000-4000-8000-000000000022_$id.pptx',
        ),
      );
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'choose':
            expect(call.arguments, isNull);
            return {'id': id, 'name': input.fileName};
          case 'stage':
            expect(call.arguments, {'id': id});
            staged.parent.createSync(recursive: true);
            staged.writeAsBytesSync(input.bytes);
            return {'path': staged.path, 'bytes': input.bytes.length};
          case 'release':
            expect(call.arguments, {'id': id});
            if (staged.existsSync()) staged.deleteSync();
            return null;
          default:
            fail('Unexpected method ${call.method}');
        }
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        PathProviderPlatform.instance = previousPaths;
      });

      final pdf = await readWhilePumping(
        tester,
        () => officePreviewPdf(PdfColors.red),
      );
      final converter = _LibraryOfficeConverter(temp, pdf);
      await mount(tester, office: converter, thumbnailCache: _NoCoverCache.new);
      Future<void> pick() async {
        final create = find.byKey(const ValueKey('library-create-button'));
        await officePreviewUntil(
          tester,
          () => create.hitTestable().evaluate().isNotEmpty,
          'The create button is available after returning to the library.',
        );
        await tester.tap(create);
        await drain(tester);
        final option = find.text('Office·한글 가져오기');
        await tester.ensureVisible(option);
        await tester.runAsync(() => tester.tap(option));
        await officePreviewUntil(
          tester,
          () => find
              .byKey(const ValueKey('office-import-mode'))
              .evaluate()
              .isNotEmpty,
          'The Android document must be chosen before mode selection.',
        );
      }

      await pick();
      expect(calls, ['choose']);
      expect(staged.existsSync(), isFalse);
      await tester.tap(find.text('취소').hitTestable());
      await officePreviewUntil(
        tester,
        () => calls.length == 2,
        'Cancellation releases the selection without copying it.',
      );
      expect(calls, ['choose', 'release']);
      expect(controller.activeSession, isNull);
      await tester.pumpAndSettle();

      await pick();
      expect(calls, ['choose', 'release', 'choose']);
      await tester.runAsync(() => tester.tap(find.text('Office 편집용')));
      await officePreviewUntil(
        tester,
        () => calls.length == 5 && controller.activeSession != null,
        'The chosen Office document opens and the staging file is released.',
      );
      expect(calls, ['choose', 'release', 'choose', 'stage', 'release']);
      expect(staged.existsSync(), isFalse);
      final note = controller.activeSession!.note;
      expect(note.documentKind, VaultDocumentKind.office);
      final edition = await readWhilePumping(
        tester,
        () => OfficeDocumentStore(controller.repository).readLatest(note),
      );
      expect(edition.originalBytes, input.bytes);
      expect(converter.calls, 0);
      final back = find.byTooltip('문서 목록으로');
      await officePreviewUntil(
        tester,
        () => back.hitTestable().evaluate().isNotEmpty && !controller.inkBusy,
        'The saved Office document can return to the library.',
      );
      await tester.runAsync(() => tester.tap(back));
      await officePreviewUntil(
        tester,
        () => find.byType(LibraryHome).evaluate().isNotEmpty,
        'The library must reopen before selecting the same file for annotation.',
      );

      calls.clear();
      await pick();
      expect(calls, ['choose']);
      await tester.runAsync(() => tester.tap(find.text('PDF 필기용')));
      await officePreviewUntil(
        tester,
        () =>
            calls.length == 3 &&
            find.byType(Editor).evaluate().isNotEmpty &&
            controller.pendingPdfPath == null &&
            !controller.inkBusy,
        'The same source can create a separate PDF in the normal ink editor.',
      );
      expect(calls, ['choose', 'stage', 'release']);
      expect(staged.existsSync(), isFalse);
      expect(converter.calls, 1);
      final pdfNote = controller.activeSession!.note;
      expect(pdfNote.documentKind, VaultDocumentKind.pdf);
      final notes = await readWhilePumping(tester, controller.store.list);
      expect(
        notes.map((entry) => entry.id),
        unorderedEquals([note.id, pdfNote.id]),
      );
      final source = await readWhilePumping(tester, () async {
        final repo = controller.repository;
        final revision = (await repo.heads(pdfNote.sourceEntityId!)).single;
        return repo.readFiles(revision);
      });
      expect(source.values.single, pdf);
      await closeOfficeFlow(tester);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets('a newly opened Office file asks how to store it once', (
    tester,
  ) async {
    final inbox = StudyWorkspace.pendingDocumentImport;
    addTearDown(() => inbox.value = null);
    final starter = OfficeTemplates.create(
      OfficeTemplateKind.document,
      title: 'Shared Word',
    );
    final file = (await tester.runAsync(
      () =>
          File('${temp.path}/${starter.fileName}').writeAsBytes(starter.bytes),
    ))!;
    await mount(tester);
    inbox.enqueue(file.path, sharedRequestId: newId());
    await officePreviewUntil(
      tester,
      () => find
          .byKey(const ValueKey('office-import-mode'))
          .evaluate()
          .isNotEmpty,
      'A newly shared Office file must show the import choice.',
    );
    expect(find.byKey(const ValueKey('office-import-mode')), findsOneWidget);
    expect(controller.activeSession, isNull);
    await tester.runAsync(() => tester.tap(find.text('Office 편집용')));
    await officePreviewUntil(
      tester,
      () => inbox.pending.isEmpty && controller.activeSession != null,
      'The selected Office document must open after import.',
    );
    expect(
      controller.activeSession?.note.documentKind,
      VaultDocumentKind.office,
    );
    expect(inbox.pending, isEmpty);
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('workspace-back-to-library'))),
    );
    await drain(tester);
    await tester.runAsync(
      () => tester.tap(
        find
            .descendant(
              of: find.byType(LibraryHome),
              matching: find.text('Shared Word'),
            )
            .first,
      ),
    );
    await officePreviewUntil(
      tester,
      () => find.text('PDF로 새 문서 만들기').hitTestable().evaluate().isNotEmpty,
      'Reopening the saved Office file must load its original actions.',
    );
    expect(find.byType(OfficeWorkspace), findsOneWidget);
    expect(find.byKey(const ValueKey('office-import-mode')), findsNothing);
    await closeOfficeFlow(tester);
  });

  testWidgets(
    'PDF choice creates a normal note and reuses a delivered request',
    (tester) => withOfficePreviewPdfium(tester, () async {
      final inbox = StudyWorkspace.pendingDocumentImport;
      final requestId = newId();
      final starter = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'Shared slides',
      );
      final (file, pdf) = await readWhilePumping(tester, () async {
        final repo = controller.repository;
        final unrelated = await repo.commit(
          entityId: newId(),
          kind: EntityKind.markdown,
          ownerNoteId: newId(),
          files: {
            'summary.md': Uint8List.fromList([1, 2, 3]),
          },
          parentRevisionIds: [],
        );
        await File('${temp.path}/blobs/${unrelated.blobs.values.single.hash}')
            .delete();
        await File('${temp.path}/revisions/${newId()}.json').writeAsString('{');
        await repo.reloadFromDisk();
        expect(repo.pendingRevisionCount, 1);
        expect(repo.integrityIssues, hasLength(2));
        return (
          await File('${temp.path}/${starter.fileName}')
              .writeAsBytes(starter.bytes),
          await officePreviewPdf(PdfColors.red),
        );
      });
      final converter = _LibraryOfficeConverter(temp, pdf);
      await mount(tester, office: converter);
      try {
        inbox.enqueue(file.path, sharedRequestId: requestId);
        final choice = find.text('PDF 필기용');
        await officePreviewUntil(
          tester,
          () => choice.hitTestable().evaluate().isNotEmpty,
          'The import choice must be presented before publishing the note.',
        );
        await tester.runAsync(() => tester.tap(choice));
        await officePreviewUntil(
          tester,
          () =>
              inbox.pending.isEmpty &&
              find.byType(Editor).evaluate().isNotEmpty &&
              controller.pendingPdfPath == null &&
              !controller.inkBusy,
          'The converted PDF must save in the ordinary ink editor despite unrelated damage.',
        );
        final notes = await readWhilePumping(tester, controller.store.list);
        expect(notes.single.documentKind, VaultDocumentKind.pdf);
        expect(notes.single.id, requestId);
        expect(find.byType(OfficeWorkspace), findsNothing);
        expect(converter.calls, 1);
        final source = await readWhilePumping(tester, () async {
          final revision = (await controller.repository.heads(
            notes.single.sourceEntityId!,
          )).single;
          return controller.repository.readFiles(revision);
        });
        expect(source.values.single, pdf);
        final kept = await readWhilePumping(
          tester,
          () => PdfNoteOriginalStore(controller.repository).read(notes.single),
        );
        expect(kept!.fileName, starter.fileName);
        expect(kept.bytes, starter.bytes);
        expect(kept.engineVersion, 'library-test');
        final savedInk = await readWhilePumping(tester, () async {
          final revision = (await controller.repository.heads(
            notes.single.inkEntityId,
          )).single;
          return controller.repository.readFiles(revision);
        });
        expect(
          PdfImportMarker.fromBytes(savedInk[PdfImportMarker.fileName]!).noteId,
          requestId,
        );
        expect(controller.repository.integrityIssues, hasLength(2));
        inbox.enqueue(file.path, sharedRequestId: requestId);
        await officePreviewUntil(
          tester,
          () => inbox.pending.isEmpty,
          'A retried share must reuse its existing PDF without asking again.',
        );
        expect(converter.calls, 1);
        expect(controller.activeSession?.note.id, requestId);
        expect(find.byKey(const ValueKey('office-import-mode')), findsNothing);
      } finally {
        inbox.value = null;
        await closeOfficeFlow(tester);
      }
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  for (final (kind, layout, size) in [
    (OfficeTemplateKind.document, 'DOCX phone', const Size(412, 892)),
    (OfficeTemplateKind.presentation, 'PPTX tablet', const Size(1200, 800)),
  ]) {
    testWidgets(
      'Office creates a separate PDF in its folder after a failed conversion ($layout)',
      (tester) => withOfficePreviewPdfium(tester, () async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final (original, goodPdf) = await readWhilePumping(tester, () async {
          final starter = OfficeTemplates.create(
            kind,
            title: 'Office original',
          );
          final folder = await controller.createFolder('Lectures');
          final repo = controller.repository;
          final note = await OfficeDocumentStore(repo).importDocument(
            title: 'Office original',
            fileName: starter.fileName,
            bytes: starter.bytes,
            folderId: folder.id,
          );
          await repo.importRevision(
            RevisionRecord(
              vaultId: repo.vaultId,
              revisionId: newId(),
              entityId: newId(),
              kind: EntityKind.attachment,
              ownerNoteId: newId(),
              deviceId: newId(),
              parentRevisionIds: [newId()],
              blobs: {},
              formatVersion: 2,
            ),
            blobsByHash: {},
          );
          await controller.openNote(note);
          return (
            note,
            await officePreviewPdf(PdfColors.red, second: PdfColors.blue),
          );
        });
        final documents = OfficeDocumentStore(controller.repository);
        final before = await readWhilePumping(
          tester,
          () => documents.readLatest(original),
        );
        final converter = _LibraryOfficeConverter(
          temp,
          Uint8List.fromList(utf8.encode('%PDF-1.7\nbroken\n%%EOF')),
        );
        final release = Completer<void>();
        await mount(tester, office: converter);
        try {
          final action = find.text('PDF로 새 문서 만들기');
          await officePreviewUntil(
            tester,
            () => action.hitTestable().evaluate().isNotEmpty,
            'The Office original must offer a new PDF document.',
          );
          expect(find.byType(SegmentedButton<bool>), findsNothing);
          await tester.runAsync(() => tester.tap(action));
          await officePreviewUntil(
            tester,
            () =>
                find.textContaining('변환한 PDF를 열 수 없습니다').evaluate().isNotEmpty,
            'An unreadable conversion must report the failure.',
          );
          final originals = await readWhilePumping(
            tester,
            controller.store.list,
          );
          expect(originals.single.id, original.id);
          expect(controller.activeSession?.note.id, original.id);
          converter
            ..output = goodPdf
            ..pageCount = 2
            ..waitForResult = release.future;
          await tester.runAsync(() => tester.tap(action));
          await officePreviewUntil(
            tester,
            () => converter.calls == 2,
            'The second conversion must reach the Office engine.',
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          release.complete();
          await officePreviewUntil(
            tester,
            () =>
                controller.activeSession?.note.documentKind ==
                    VaultDocumentKind.pdf &&
                find.byType(Editor).evaluate().isNotEmpty &&
                controller.pendingPdfPath == null &&
                !controller.inkBusy,
            'The valid conversion must open a different document in the PDF editor.',
          );
          final notes = await readWhilePumping(tester, controller.store.list);
          expect(notes, hasLength(2));
          final copy = notes.singleWhere(
            (note) => note.documentKind == VaultDocumentKind.pdf,
          );
          expect(copy.id, isNot(original.id));
          expect(copy.folderId, original.folderId);
          expect(find.byType(OfficeWorkspace), findsNothing);
          final editor = tester.state<EditorState>(find.byType(Editor));
          await officePreviewUntil(
            tester,
            () => editor.coreInfo.pages.firstOrNull?.renderBox != null,
            'The PDF must render in the ordinary ink canvas.',
          );
          expect(editor.coreInfo.readOnly, isFalse);
          final page = editor.coreInfo.pages.first;
          final box = page.renderBox!;
          final center =
              Rect.fromPoints(
                    box.localToGlobal(Offset.zero),
                    box.localToGlobal(page.size.bottomRight(Offset.zero)),
                  )
                  .intersect(
                    tester.getRect(find.byType(InteractiveCanvasViewer)),
                  )
                  .center;
          final pen = await tester.createGesture(
            kind: PointerDeviceKind.stylus,
          );
          await pen.down(center - const Offset(30, 5));
          await pen.moveTo(center);
          await pen.moveTo(center + const Offset(30, 5));
          await pen.up();
          await tester.pump();
          expect(page.strokes, hasLength(1));
          await readWhilePumping(tester, editor.saveToFile);
          final reopened = await readWhilePumping(tester, controller.loadInk);
          try {
            expect(
              reopened.pages
                  .map((page) => page.backgroundImage)
                  .whereType<PdfEditorImage>()
                  .map((image) => image.pdfPage),
              orderedEquals([0, 1]),
            );
            expect(reopened.pages.first.strokes, hasLength(1));
          } finally {
            reopened.dispose();
          }
          expect(controller.repository.pendingRevisionCount, 1);
          final after = await readWhilePumping(
            tester,
            () => documents.readLatest(original),
          );
          expect(after.revision.revisionId, before.revision.revisionId);
          expect(after.originalBytes, before.originalBytes);
          expect(
            await readWhilePumping(
              tester,
              () => documents.readPdfVariants(original, after),
            ),
            isEmpty,
          );
          expect(converter.calls, 2);
        } finally {
          if (!release.isCompleted) release.complete();
          await closeOfficeFlow(tester);
        }
      }),
      skip: !officePreviewPdfiumAvailable,
    );
  }

  final hwpLibrary = Platform.environment['PIV_HWP_DELETE_TEST_DLL'];
  final hwpFixtures = Platform.environment['PIV_HWP_DELETE_TEST_FIXTURES'];
  for (final (sourceName, firstOpen, size) in const [
    ('original.hwp', true, Size(412, 892)),
    ('clean-original.hwpx', false, Size(1200, 800)),
  ]) {
    final fixture = hwpFixtures == null
        ? null
        : File('$hwpFixtures/$sourceName');
    testWidgets(
      'Android creates a writable PDF from real $sourceName',
      (tester) => withOfficePreviewPdfium(tester, () async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final (input, original) = await readWhilePumping(tester, () async {
          final bytes = await fixture!.readAsBytes();
          final folder = await controller.createFolder('한글 자료');
          await controller.openFolder(folder.id);
          if (firstOpen) return (bytes, null);
          final note = await OfficeDocumentStore(controller.repository)
              .importDocument(
                title: '한글 자료',
                fileName: sourceName,
                bytes: bytes,
                folderId: folder.id,
              );
          await controller.openNote(note);
          return (bytes, note);
        });
        final engine = OfficePreviewEngine(
          hwpEngine: HwpStructuredOfficeEngine(
            libraryPath: hwpLibrary,
            fontDirectory: Directory('build/native/fonts').absolute.path,
          ),
          isAndroid: true,
          isWindows: false,
        );
        final inbox = StudyWorkspace.pendingDocumentImport;
        await mount(tester, office: engine);
        try {
          if (firstOpen) inbox.enqueue(fixture!.path, sharedRequestId: newId());
          final action = find.text(firstOpen ? 'PDF 필기용' : 'PDF로 새 문서 만들기');
          await officePreviewUntil(
            tester,
            () => action.hitTestable().evaluate().isNotEmpty,
            'Android must offer PDF creation for a real HWP or HWPX file.',
          );
          await tester.runAsync(() => tester.tap(action));
          await officePreviewUntil(
            tester,
            () =>
                controller.activeSession?.note.documentKind ==
                    VaultDocumentKind.pdf &&
                find.byType(Editor).evaluate().isNotEmpty &&
                controller.pendingPdfPath == null &&
                !controller.inkBusy &&
                inbox.pending.isEmpty,
            'The Rust-rendered PDF must save and open in the ink editor.',
          );
          final copy = controller.activeSession!.note;
          await readWhilePumping(tester, () async {
            final notes = await controller.store.list();
            expect(notes, hasLength(firstOpen ? 1 : 2));
            expect(copy.folderId, isNotNull);
            if (original != null) {
              expect(copy.folderId, original.folderId);
              final edition = await OfficeDocumentStore(controller.repository)
                  .readLatest(original);
              expect(edition.originalBytes, input);
              expect(edition.pdfBytes, isNull);
            }
            final source = (await controller.repository.heads(
              copy.sourceEntityId!,
            )).single;
            final bytes = (await controller.repository.readFiles(source))
                .values
                .single;
            final pdf = await PdfDocument.openData(
              bytes,
              useProgressiveLoading: false,
            );
            try {
              expect(pdf.pages, hasLength(1));
              final text = (await pdf.pages.single.loadText())!.fullText;
              expect(
                text.replaceAll(RegExp(r'\s+'), ''),
                contains(firstOpen ? '2026' : 'PIV_DELETE_THIS_PARAGRAPH'),
              );
            } finally {
              await pdf.dispose();
            }
            expect(await fixture!.readAsBytes(), input);
          });
          final editor = tester.state<EditorState>(find.byType(Editor));
          await officePreviewUntil(
            tester,
            () => editor.coreInfo.pages.firstOrNull?.renderBox != null,
            'The rendered HWP page must accept pen input.',
          );
          expect(editor.coreInfo.readOnly, isFalse);
          final page = editor.coreInfo.pages.first;
          expect(page.backgroundImage, isA<PdfEditorImage>());
          final box = page.renderBox!;
          final visiblePage = Rect.fromPoints(
            box.localToGlobal(Offset.zero),
            box.localToGlobal(page.size.bottomRight(Offset.zero)),
          ).intersect(tester.getRect(find.byType(InteractiveCanvasViewer)));
          final center = visiblePage.center;
          final pen = await tester.createGesture(
            kind: PointerDeviceKind.stylus,
          );
          await pen.down(center - const Offset(24, 4));
          await pen.moveTo(center);
          await pen.moveTo(center + const Offset(24, 4));
          await pen.up();
          await tester.pump();
          expect(page.strokes, hasLength(1));
          await readWhilePumping(tester, editor.saveToFile);
          final saved = await readWhilePumping(tester, controller.loadInk);
          try {
            expect(saved.pages.first.strokes, hasLength(1));
            expect(saved.pages.first.backgroundImage, isA<PdfEditorImage>());
          } finally {
            saved.dispose();
          }
        } finally {
          inbox.value = null;
          await closeOfficeFlow(tester);
        }
      }),
      skip:
          !officePreviewPdfiumAvailable ||
          hwpLibrary == null ||
          fixture?.existsSync() != true,
    );
  }

  testWidgets('library batch selection handles back before leaving a folder', (
    tester,
  ) async {
    final folder = await tester.runAsync(
      () => controller.createFolder('Folder'),
    );
    await tester.runAsync(() async {
      await controller.openFolder(folder!.id);
      await controller.store.create(
        'Selected document',
        folderId: folder.id,
        documentKind: VaultDocumentKind.markdown,
      );
      await controller.refresh();
    });
    await mount(tester);
    final toggle = find.byKey(const ValueKey('library-select-mode'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.byKey(const ValueKey('library-select-all')), findsOneWidget);
    await tester.runAsync(tester.binding.handlePopRoute);
    await drain(tester);
    expect(controller.currentFolderId, folder!.id);
    expect(find.byKey(const ValueKey('library-select-all')), findsNothing);
    await tester.runAsync(tester.binding.handlePopRoute);
    await drain(tester);
    expect(controller.currentFolderId, isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('library batch move, trash cancel, trash and restore', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 950);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (source, destination, first, second, outside) = (await tester
        .runAsync(() async {
          final source = await controller.createFolder('Source folder');
          final destination = await controller.createFolder('Target folder');
          await controller.openFolder(source.id);
          final store = controller.store;
          final first = await store.create(
            'Alpha',
            folderId: source.id,
            documentKind: VaultDocumentKind.markdown,
          );
          final second = await store.create(
            'Beta',
            folderId: source.id,
            documentKind: VaultDocumentKind.markdown,
          );
          final outside = await store.create(
            'Unselected pen note',
            folderId: source.id,
          );
          await controller.refresh();
          return (source, destination, first, second, outside);
        }))!;
    await mount(tester);
    Finder key(String key) => find.byKey(ValueKey(key));
    await tester.tap(key('library-select-mode'));
    await tester.pump();
    await tester.tap(key('library-filter-markdown'));
    await tester.pump();
    final alpha = key('library-select-note-${first.id}');
    final beta = key('library-select-note-${second.id}');
    expect(alpha, findsOneWidget);
    await tester.tap(alpha);
    await tester.pump();
    expect(find.text('1개 선택'), findsOneWidget);
    await tester.tap(key('library-layout-toggle'));
    await tester.pump();
    expect(tester.widget<Checkbox>(alpha).value, isTrue);
    expect(key('library-select-note-${outside.id}'), findsNothing);
    await tester.tap(key('library-select-all'));
    await tester.pump();
    expect(tester.widget<Checkbox>(beta).value, isTrue);
    expect(find.text('2개 선택'), findsOneWidget);

    await tester.runAsync(() => tester.tap(key('library-batch-move')));
    await drain(tester);
    final target = find.widgetWithText(SimpleDialogOption, 'Target folder');
    await tester.runAsync(() => tester.tap(target));
    await drain(tester);
    final moved = await readWhilePumping(
      tester,
      () => controller.store.list(includeDeleted: true),
    );
    expect(
      moved.where((note) => note.folderId == destination.id).map((n) => n.id),
      unorderedEquals([first.id, second.id]),
    );
    expect(moved.singleWhere((n) => n.id == outside.id).folderId, source.id);
    expect(find.text('0개 선택'), findsOneWidget);

    await tester.runAsync(() => controller.openFolder(destination.id));
    await drain(tester);
    expect(key('library-select-all'), findsNothing);
    await tester.tap(key('library-select-mode'));
    await tester.pump();
    await tester.tap(key('library-select-all'));
    await tester.pump();
    await tester.runAsync(() => tester.tap(key('library-batch-trash')));
    await drain(tester);
    expect(find.text('문서 2개 휴지통 이동'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.text('취소')));
    await drain(tester);
    expect(find.text('2개 선택'), findsOneWidget);
    final afterCancel = await readWhilePumping(
      tester,
      () => controller.store.list(includeDeleted: true),
    );
    expect(
      afterCancel.map((n) => n.revision.revisionId),
      unorderedEquals(moved.map((n) => n.revision.revisionId)),
    );
    await tester.runAsync(() => tester.tap(key('library-batch-trash')));
    await drain(tester);
    await tester.runAsync(() => tester.tap(key('library-batch-confirm')));
    await drain(tester);
    final trashed = await readWhilePumping(
      tester,
      () => controller.store.list(includeDeleted: true),
    );
    expect(
      trashed.where((n) => n.trashed).map((n) => n.id),
      unorderedEquals([first.id, second.id]),
    );

    final trash = find.widgetWithText(ListTile, '휴지통');
    await tester.runAsync(() => tester.tap(trash));
    await drain(tester);
    expect(key('library-select-all'), findsNothing);
    await tester.tap(key('library-select-mode'));
    await tester.pump();
    await tester.tap(key('library-select-all'));
    await tester.pump();
    await tester.runAsync(() => tester.tap(key('library-batch-restore')));
    await drain(tester);
    await tester.runAsync(() => tester.tap(key('library-batch-confirm')));
    await drain(tester);
    final restored = await readWhilePumping(
      tester,
      () => controller.store.list(includeDeleted: true),
    );
    expect(restored.any((n) => n.trashed), isFalse);
    expect(
      restored.where((n) => n.folderId == destination.id).map((n) => n.id),
      unorderedEquals([first.id, second.id]),
    );
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('library batch retains a revised item after partial move', (
    tester,
  ) async {
    final (destination, first, second) = (await tester.runAsync(() async {
      final source = await controller.createFolder('Source folder');
      final destination = await controller.createFolder('Target folder');
      await controller.openFolder(source.id);
      final first = await controller.store.create(
        'Alpha',
        folderId: source.id,
        documentKind: VaultDocumentKind.markdown,
      );
      final second = await controller.store.create(
        'Beta',
        folderId: source.id,
        documentKind: VaultDocumentKind.markdown,
      );
      await controller.refresh();
      return (destination, first, second);
    }))!;
    await mount(tester);
    Finder key(String key) => find.byKey(ValueKey(key));
    await tester.tap(key('library-select-mode'));
    await tester.pump();
    await tester.tap(key('library-select-all'));
    await tester.pump();
    await tester.runAsync(() => tester.tap(key('library-batch-move')));
    await drain(tester);
    await tester.runAsync(() async {
      await controller.store.rename(second, 'Beta revised');
      await controller.refresh();
    });
    final target = find.widgetWithText(SimpleDialogOption, 'Target folder');
    await tester.runAsync(() => tester.tap(target));
    final partialNotice = find.textContaining('1개 이동 완료 · 1개 미처리');
    for (var i = 0; i < 12 && partialNotice.evaluate().isEmpty; i++) {
      await drain(tester);
    }
    expect(partialNotice, findsOneWidget);
    final partial = await readWhilePumping(tester, controller.store.list);
    expect(
      partial.singleWhere((n) => n.id == first.id).folderId,
      destination.id,
    );
    expect(
      partial.singleWhere((n) => n.id == second.id).folderId,
      second.folderId,
    );
    expect(find.text('1개 선택'), findsOneWidget);

    final move = key('library-batch-move');
    expect(tester.widget<TextButton>(move).onPressed, isNotNull);
    await tester.runAsync(() => tester.tap(move));
    await drain(tester);
    expect(target.hitTestable(), findsOneWidget);
    await tester.runAsync(() => tester.tap(target));
    for (var i = 0; i < 8 && find.text('0개 선택').evaluate().isEmpty; i++) {
      await drain(tester);
    }
    final retried = await readWhilePumping(tester, controller.store.list);
    expect(
      retried.where((n) => n.folderId == destination.id).map((n) => n.title),
      unorderedEquals(['Alpha', 'Beta revised']),
      reason: find
          .byType(SnackBar)
          .evaluate()
          .map((e) {
            final content = (e.widget as SnackBar).content;
            return content is Text ? content.data : content;
          })
          .join(' / '),
    );
    expect(find.text('0개 선택'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('library exposes vault bookmarks', (tester) async {
    await mount(tester);
    expect(find.byKey(const ValueKey('workspace-bookmarks')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('search expressions do not fall back to ordinary search', (
    tester,
  ) async {
    await readWhilePumping(tester, () async {
      await controller.store.createMarkdown(
        '검색식 동작 확인',
        Uint8List.fromList(utf8.encode('content:example')),
      );
      await controller.refresh();
    });
    await mount(tester);
    final field = find.byKey(const ValueKey('library-search'));
    final toggle = find.byKey(const ValueKey('library-search-expression'));
    final error = find.byKey(const ValueKey('library-search-error'));
    expect(toggle, findsOneWidget);
    await tester.runAsync(() => tester.enterText(field, 'content:example'));
    await drain(tester);
    expect(find.text('검색식 동작 확인'), findsOneWidget);

    await tester.runAsync(() => tester.tap(toggle));
    await drain(tester);
    expect(error, findsOneWidget);
    expect(find.text('검색식 동작 확인'), findsNothing);

    await tester.runAsync(() => tester.tap(toggle));
    await drain(tester);
    expect(error, findsNothing);
    expect(find.text('검색식 동작 확인'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  final nativeLibrary = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'search excerpt opens and selects the matching Markdown on ${platform.name}',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final prefix =
              '# 처음 😀\r\n\r\n'
              '${List.generate(78, (i) => '앞부분 $i\r\n\r\n').join()}'
              '여기 😀 ';
          const matched = 'Cafe\u0301 목표 문장';
          final source = '$prefix$matched 다음 문장';
          final note = await readWhilePumping(tester, () async {
            final original = controller;
            await original.flush();
            original.dispose();
            await original.repository.close();
            controller = WorkspaceController(
              await NoteRepository.open(
                Directory('${temp.path}/native-body-search'),
                createFormatVersion: 2,
              ),
              native: InkVaultNative.open(libraryPath: nativeLibrary!),
            );
            final note = await controller.store.createMarkdown(
              '긴 검색 문서',
              Uint8List.fromList(utf8.encode(source)),
            );
            await controller.refresh();
            return note;
          });
          await mount(tester);
          final field = find.byKey(const ValueKey('library-search'));
          final toggle = find.byKey(
            const ValueKey('library-search-expression'),
          );
          await tester.runAsync(() => tester.tap(toggle));
          await tester.runAsync(
            () => tester.enterText(field, 'content:"café 목표 문장"'),
          );
          await drain(tester);
          final excerpt = find.byKey(
            ValueKey('library-search-body-${note.id}'),
          );
          expect(excerpt, findsOneWidget);
          expect(
            find.descendant(
              of: excerpt,
              matching: find.textContaining(matched),
            ),
            findsOneWidget,
          );
          await tester.ensureVisible(excerpt);
          await tester.runAsync(() => tester.tap(excerpt));
          await drain(tester);
          final editor = find.descendant(
            of: find.byType(MarkdownEditor),
            matching: find.byWidgetPredicate(
              (widget) => widget is EditableText && !widget.readOnly,
            ),
          );
          expect(editor, findsOneWidget);
          final state = tester.state<EditableTextState>(editor);
          expect(state.widget.controller.text, source);
          expect(
            state.widget.controller.selection,
            TextSelection(
              baseOffset: prefix.length,
              extentOffset: prefix.length + matched.length,
            ),
          );
          expect(state.renderEditable.offset.pixels, greaterThan(0));
          expect(controller.markdownDirty, isFalse);
          expect(controller.navigation.current.markdownAnchor, isNull);
          if (platform == TargetPlatform.android) {
            await tester.tap(find.byTooltip('미리보기'));
            await drain(tester);
            Future<void> openOwnLink([String? anchor]) async {
              final widget = tester.widget<MarkdownEditor>(
                find.byType(MarkdownEditor),
              );
              await tester.runAsync(
                () async => widget.onOpenLink(
                  NoteLink.markdown(note.id, anchor).toString(),
                ),
              );
              await drain(tester);
            }

            await openOwnLink('처음 😀');
            expect(controller.navigation.current.markdownAnchor, '처음 😀');
            await openOwnLink();
            expect(controller.navigation.current.markdownAnchor, isNull);
            expect(editor, findsNothing);
            await tester.runAsync(
              () => tester.tap(
                find.byKey(const ValueKey('workspace-back-to-library')),
              ),
            );
            await drain(tester);
            final previousTap = tester.widget<TextButton>(excerpt).onPressed!;
            final changed = '추가한 첫 줄\r\n$source';
            await readWhilePumping(tester, () async {
              final external = await controller.store.open(note);
              await external.saveMarkdown(changed);
              await controller.refresh();
            });
            await tester.runAsync(() async => previousTap());
            await drain(tester);
            expect(controller.activeSession?.note.id, note.id);
            expect(controller.markdown, changed);
            expect(editor, findsNothing);
            expect(controller.markdownDirty, isFalse);
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          debugDefaultTargetPlatformOverride = null;
        }
      },
      skip: nativeLibrary == null,
    );
  }
  testWidgets(
    'library searches every folder and recovers from invalid syntax',
    (tester) async {
      await readWhilePumping(tester, () async {
        final original = controller;
        await original.flush();
        original.dispose();
        await original.repository.close();
        controller = WorkspaceController(
          await NoteRepository.open(
            Directory('${temp.path}/native-search'),
            createFormatVersion: 2,
          ),
          native: InkVaultNative.open(libraryPath: nativeLibrary!),
        );
        final folder = await controller.createFolder('세미나 자료');
        await controller.store.createMarkdown(
          '검색식 결과',
          Uint8List.fromList(utf8.encode('다음 발표 자료 #세미나')),
          folderId: folder.id,
        );
        await controller.store.createMarkdown(
          '검색식 초안',
          Uint8List.fromList(utf8.encode('다음 발표 자료 #세미나')),
          folderId: folder.id,
        );
        await controller.openFolder(null);
        await controller.refresh();
      });
      await mount(tester);
      final field = find.byKey(const ValueKey('library-search'));
      final toggle = find.byKey(const ValueKey('library-search-expression'));
      final error = find.byKey(const ValueKey('library-search-error'));
      final result = find.text('검색식 결과');
      const expression = 'path:"세미나 자료" tag:#세미나 -file:초안';
      expect(result, findsNothing);
      await tester.runAsync(() => tester.tap(toggle));
      await tester.runAsync(() => tester.enterText(field, expression));
      await drain(tester);
      expect(result, findsOneWidget);
      expect(find.text('검색식 초안'), findsNothing);

      await tester.runAsync(() => tester.enterText(field, 'tag:'));
      await drain(tester);
      expect(error, findsOneWidget);
      expect(result, findsNothing);

      await tester.runAsync(() => tester.enterText(field, expression));
      await drain(tester);
      expect(error, findsNothing);
      expect(result, findsOneWidget);

      Future<void> tap(String key) async {
        final button = find.byKey(ValueKey(key));
        for (var i = 0; i < 12 && button.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        await tester.runAsync(() => tester.tap(button));
        await drain(tester);
      }

      await tap('workspace-bookmarks');
      await tap('workspace-bookmark-add-current');
      await tap('workspace-bookmark-target-0');
      await tap('workspace-bookmark-confirm');
      final saved = await readWhilePumping(
        tester,
        () => WorkspaceBookmarkStore(controller.repository).list(),
      );
      expect(saved.single.spec.target, expression);
      expect(saved.single.spec.expressionSearch, isTrue);
      await readWhilePumping(tester, () async {
        controller.setSearchQuery('');
        await controller.refresh();
      });
      await tap(
        'workspace-bookmark-open-${saved.single.id}-${saved.single.revisionId}',
      );
      expect(controller.searchesWithOperators, isTrue);
      expect(tester.widget<TextField>(field).controller?.text, expression);
      for (var i = 0; i < 12 && controller.searchPending; i++) {
        await drain(tester);
      }
      expect(result, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
    skip: nativeLibrary == null,
  );

  test('failed vault switch restores the previous search expression', () async {
    final original = controller;
    await original.flush();
    original.dispose();
    await original.repository.close();
    final previous = await NoteRepository.open(temp, createFormatVersion: 2);
    var rejectSelection = true;
    controller = WorkspaceController(
      previous,
      directoryProvider: () async {
        if (rejectSelection) throw const FileSystemException('selection write');
        return Directory('${temp.path}/support');
      },
    );
    const query = 'path:archive';
    controller.setSearchQuery(query, expression: true);
    await controller.refresh();
    final searchError = controller.searchError;
    expect(searchError, isNotNull);

    final next = await NoteRepository.open(
      Directory('${temp.path}/another-vault'),
      createFormatVersion: 2,
    );
    await expectLater(
      controller.replaceRepository(next),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.repository, same(previous));
    expect(controller.query, query);
    expect(controller.searchesWithOperators, isTrue);
    expect(controller.searchesFromBookmark, isFalse);
    expect(controller.searchError, searchError);

    rejectSelection = false;
    await controller.replaceRepository(next);
    expect(controller.repository, same(next));
    expect(controller.query, isEmpty);
    expect(controller.searchesWithOperators, isFalse);
    expect(controller.searchError, isNull);
  });

  testWidgets('bookmarks reopen a renamed heading and search across folders', (
    tester,
  ) async {
    final note = await readWhilePumping(tester, () async {
      if (Platform.environment['INK_VAULT_NATIVE_LIBRARY']
          case final library?) {
        final original = controller;
        await original.flush();
        original.dispose();
        await original.repository.close();
        controller = WorkspaceController(
          await NoteRepository.open(
            Directory('${temp.path}/native-bookmarks'),
            createFormatVersion: 2,
          ),
          native: InkVaultNative.open(libraryPath: library),
        );
      }
      final folder = await controller.createFolder('강의 자료');
      final note = await controller.store.createMarkdown(
        '기존 제목',
        Uint8List.fromList(utf8.encode('# 연습 문제\n\n특별 검색어')),
        folderId: folder.id,
      );
      await controller.store.createMarkdown(
        '다른 어순',
        Uint8List.fromList(utf8.encode('검색어 뒤에 특별')),
        folderId: folder.id,
      );
      final bookmarks = WorkspaceBookmarkStore(controller.repository);
      await bookmarks.add(
        WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.note,
          title: '저장한 제목 위치',
          target: NoteLink.markdown(note.id, '연습 문제').toString(),
        ),
      );
      await bookmarks.add(
        const WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.search,
          title: '저장한 검색',
          target: '특별 검색어',
          literalSearch: true,
        ),
      );
      await bookmarks.add(
        const WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.search,
          title: '기기에서 저장한 검색',
          target: '특별 검색어',
        ),
      );
      await controller.store.rename(note, '변경한 제목');
      await controller.refresh();
      return note;
    });
    await mount(tester);
    final bookmarks = find.byKey(const ValueKey('workspace-bookmarks'));
    Future<void> openBookmark(String title) async {
      for (
        var i = 0;
        i < 16 && tester.widget<IconButton>(bookmarks).onPressed == null;
        i++
      ) {
        await drain(tester);
      }
      expect(tester.widget<IconButton>(bookmarks).onPressed, isNotNull);
      await tester.runAsync(() => tester.tap(bookmarks));
      final row = find.text(title);
      for (var i = 0; i < 12 && row.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(row, findsOneWidget);
      await tester.runAsync(() => tester.tap(row));
      await drain(tester);
    }

    await openBookmark('저장한 제목 위치');
    // Opening saves and reads the note on real time; one drain was not always enough.
    for (
      var i = 0;
      i < 12 && controller.activeSession?.note.id != note.id;
      i++
    ) {
      await drain(tester);
    }
    expect(controller.activeSession?.note.id, note.id);
    expect(controller.activeSession?.note.title, '변경한 제목');
    expect(controller.navigation.current.markdownAnchor, '연습 문제');
    await openBookmark('저장한 검색');
    for (
      var i = 0;
      i < 12 &&
          (controller.currentFolderId != null ||
              controller.query != '특별 검색어' ||
              !controller.notes.any((item) => item.id == note.id));
      i++
    ) {
      await drain(tester);
    }
    expect(controller.activeSession, isNull);
    expect(controller.currentFolderId, isNull);
    final search = tester.widget<TextField>(
      find.byKey(const ValueKey('library-search')),
    );
    expect(search.controller?.text, '특별 검색어');
    expect(find.text('변경한 제목'), findsWidgets);
    expect(find.text('다른 어순'), findsNothing);
    if (controller.native != null) {
      await openBookmark('기기에서 저장한 검색');
      for (var i = 0; i < 12 && find.text('다른 어순').evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(controller.searchesLiterally, isFalse);
      expect(find.text('다른 어순'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('quick note saves a page in the selected folder and reopens it', (
    tester,
  ) async {
    final (folder, markdown) = await readWhilePumping(tester, () async {
      final folder = await controller.createFolder('강의 메모');
      final markdown = await controller.store.createMarkdown(
        '이전 Markdown',
        Uint8List.fromList(utf8.encode('Markdown 내용')),
      );
      await controller.openNote(markdown);
      return (folder, markdown);
    });
    await mount(tester);
    expect(controller.activeSession?.note.id, markdown.id);
    await tester.runAsync(() async {
      tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    });
    await drain(tester);
    await tester.runAsync(
      () async => tester.tap(find.widgetWithText(ListTile, folder.title)),
    );
    for (var i = 0; i < 12 && controller.currentFolderId != folder.id; i++) {
      await drain(tester);
    }
    expect(controller.activeSession, isNull);
    expect(controller.currentFolderId, folder.id);
    await tester.runAsync(
      () async =>
          tester.tap(find.byKey(const ValueKey('library-create-button'))),
    );
    await drain(tester);
    final quick = find.widgetWithText(
      PopupMenuItem<LibraryCreateAction>,
      '빠른 메모',
    );
    expect(quick, findsOneWidget);
    await tester.runAsync(() async => tester.tap(quick));
    for (var i = 0; i < 20 && find.byType(Editor).evaluate().isEmpty; i++) {
      await drain(tester);
    }
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.byType(Editor),
      findsOneWidget,
      reason:
          'error=${controller.error}; active=${controller.activeSession?.note.id}; '
          'messages=${tester.widgetList<Text>(find.descendant(of: find.byType(SnackBar), matching: find.byType(Text))).map((text) => text.data)}',
    );
    final note = controller.activeSession!.note;
    expect(note.title, '빠른 메모');
    expect(note.folderId, folder.id);
    expect(note.documentKind, VaultDocumentKind.handwriting);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
    expect(
      (await readWhilePumping(
        tester,
        controller.store.list,
      )).where((value) => value.folderId == folder.id).single.id,
      note.id,
    );

    await tester.runAsync(
      () async => tester.tap(find.byTooltip('문서 목록으로').last),
    );
    await drain(tester);
    expect(controller.currentFolderId, folder.id);
    final card = find.byKey(
      ValueKey('library-note-${note.revision.revisionId}'),
    );
    expect(card, findsOneWidget);
    // Back saves and closes the note before the workspace takes taps again.
    for (
      var i = 0;
      i < 12 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
      i++
    ) {
      await drain(tester);
    }
    await tester.runAsync(() async => tester.tap(card));
    for (var i = 0; i < 20 && find.byType(Editor).evaluate().isEmpty; i++) {
      await drain(tester);
    }
    expect(controller.activeSession?.note.id, note.id);
    expect(
      tester.state<EditorState>(find.byType(Editor)).coreInfo.pages,
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      '${platform.name} library opens daily note template settings and applies once',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final template = await readWhilePumping(tester, () async {
          final folder = await controller.createFolder('일지 양식 폴더');
          final note = await controller.store.createMarkdown(
            '실험 일지 양식',
            Uint8List.fromList(utf8.encode('# {{title}}\n## 오늘 기록')),
            folderId: folder.id,
          );
          await controller.refresh();
          return note;
        });
        await mount(tester);
        Future<void> choose(String label) async {
          await tester.runAsync(
            () =>
                tester.tap(find.byKey(const ValueKey('library-create-button'))),
          );
          await tester.pumpAndSettle();
          final action = find.text(label);
          expect(action, findsOneWidget);
          await tester.ensureVisible(action);
          await tester.runAsync(() => tester.tap(action));
          await drain(tester);
        }

        await choose('날짜별 노트 템플릿');
        expect(
          find.byKey(const ValueKey('daily-note-template-settings')),
          findsOneWidget,
        );
        final choice = find.byKey(
          ValueKey('daily-note-template-choice-${template.id}'),
        );
        final folder = find.byKey(const ValueKey('daily-note-template-folder'));
        final dropdown = tester.widget<DropdownButtonFormField<String>>(folder);
        if (dropdown.initialValue == null) {
          await tester.tap(folder);
          await tester.pumpAndSettle();
          await tester.runAsync(() => tester.tap(find.text('일지 양식 폴더').last));
        }
        for (var i = 0; i < 10 && choice.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(
          choice,
          findsOneWidget,
          reason: tester
              .widgetList<Text>(
                find.descendant(
                  of: find.byKey(
                    const ValueKey('daily-note-template-settings'),
                  ),
                  matching: find.byType(Text),
                ),
              )
              .map((text) => text.data)
              .join(' · '),
        );
        await tester.tap(choice);
        await tester.pump();
        await tester.runAsync(
          () => tester.tap(
            find.byKey(const ValueKey('daily-note-template-save')),
          ),
        );
        await drain(tester);
        final settings = WorkspaceMarkdownTemplateStore(controller.repository);
        expect(
          (await readWhilePumping(
            tester,
            settings.dailyNoteTemplateSettings,
          )).noteId,
          template.id,
        );

        await choose('오늘 노트');
        for (var i = 0; i < 20 && controller.activeSession == null; i++) {
          await drain(tester);
        }
        expect(controller.activeSession, isNotNull);
        final daily = controller.activeSession!.note;
        expect(controller.markdown, '# ${daily.title}\n## 오늘 기록');
        await tester.runAsync(() async {
          controller.editMarkdown('작성한 기록');
          await controller.flush();
        });
        final back = find
            .byKey(const ValueKey('workspace-back-to-library'))
            .hitTestable();
        bool backReady() =>
            back.evaluate().length == 1 &&
            tester.widget<IconButton>(back).onPressed != null;
        for (var i = 0; i < 20 && !backReady(); i++) {
          await drain(tester);
        }
        expect(backReady(), isTrue, reason: 'The daily editor must be ready.');
        await tester.runAsync(() => tester.tap(back));
        final home = find.byType(LibraryHome);
        for (var i = 0; i < 20 && home.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(home, findsOneWidget);
        expect(controller.activeSession, isNull);
        await choose('날짜별 노트 템플릿');
        await tester.runAsync(
          () => tester.tap(
            find.byKey(const ValueKey('daily-note-template-clear')),
          ),
        );
        await drain(tester);
        expect(
          (await readWhilePumping(
            tester,
            settings.dailyNoteTemplateSettings,
          )).noteId,
          isNull,
        );

        await choose('오늘 노트');
        expect(controller.activeSession!.note.id, daily.id);
        expect(controller.markdown, '작성한 기록');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('today and the date picker reopen the same saved daily note', (
    tester,
  ) async {
    await mount(tester);
    Future<void> choose(String label) async {
      await tester.runAsync(
        () async =>
            tester.tap(find.byKey(const ValueKey('library-create-button'))),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(label));
      await tester.runAsync(() async => tester.tap(find.text(label)));
      await drain(tester);
    }

    await choose('오늘 노트');
    for (
      var attempt = 0;
      attempt < 20 && find.byType(MarkdownEditor).evaluate().isEmpty;
      attempt++
    ) {
      await drain(tester);
    }
    expect(
      find.byType(MarkdownEditor),
      findsOneWidget,
      reason:
          'error=${controller.error}; active=${controller.activeSession?.note.id}; '
          'messages=${tester.widgetList<Text>(find.descendant(of: find.byType(SnackBar), matching: find.byType(Text))).map((text) => text.data)}',
    );
    final note = controller.activeSession!.note;
    expect(note.folderId, isNull);
    expect(note.json['dailyDate'], matches(r'^\d{4}-\d{2}-\d{2}$'));
    await tester.runAsync(() async {
      controller.editMarkdown('보존할 기록');
      await controller.flush();
    });
    await drain(tester);
    await tester.runAsync(
      () async => tester.tap(find.byTooltip('문서 목록으로').last),
    );
    await drain(tester);
    expect(find.byType(LibraryHome), findsOneWidget);

    await choose('날짜별 노트');
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.runAsync(() async => tester.tap(find.text('열기')));
    await drain(tester);
    expect(controller.activeSession!.note.id, note.id);
    expect(controller.markdown, '보존할 기록');
    expect(controller.notes, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  for (final (label, kind) in [
    ('블록 페이지', VaultDocumentKind.page),
    ('Word 문서 만들기', VaultDocumentKind.office),
  ]) {
    testWidgets('legacy vault creation upgrades before creating $kind', (
      tester,
    ) async {
      await tester.runAsync(() async {
        controller.dispose();
        await controller.repository.close();
      });
      final paths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _LibraryTestPaths(temp.path);
      addTearDown(() => PathProviderPlatform.instance = paths);
      final source = Directory('${temp.path}/legacy');
      final original = (await tester.runAsync(() async {
        final repository = await NoteRepository.open(
          source,
          createFormatVersion: 1,
        );
        controller = WorkspaceController(
          repository,
          directoryProvider: () async => temp,
        );
        final original = await controller.store.create('기존 필기');
        await controller.refresh();
        return original;
      }))!;
      await mount(tester);

      Future<void> choose() async {
        await tester.tap(find.byKey(const ValueKey('library-create-button')));
        await tester.pumpAndSettle();
        final option = find.text(label);
        await tester.ensureVisible(option);
        await tester.runAsync(() => tester.tap(option));
        await drain(tester);
        expect(find.text('보관함 형식 업데이트'), findsOneWidget);
      }

      try {
        await choose();
        await tester.tap(find.text('취소'));
        await drain(tester);
        expect(controller.repository.formatVersion, 1);
        expect(controller.notes.map((note) => note.id), [original.id]);

        await choose();
        await tester.runAsync(() => tester.tap(find.text('형식 2 복사본 만들기')));
        for (var i = 0; i < 10 && find.text('문서 이름').evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(find.text('문서 이름'), findsOneWidget);
        expect(controller.repository.formatVersion, 2);
        expect(controller.repository.root.path, isNot(source.path));
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '새 자료',
        );
        await tester.runAsync(() => tester.tap(find.text('확인')));
        for (var i = 0; i < 20 && controller.activeSession == null; i++) {
          await drain(tester);
        }
        expect(controller.activeSession?.note.documentKind, kind);
        expect(controller.notes.map((note) => note.id), contains(original.id));
        if (kind == VaultDocumentKind.office) {
          final edition = await readWhilePumping(
            tester,
            () =>
                OfficeDocumentStore(controller.repository)
                    .readLatest(controller.activeSession!.note),
          );
          expect(edition.originalFileName, endsWith('.docx'));
          expect(
            ZipDecoder()
                .decodeBytes(edition.originalBytes)
                .findFile('word/document.xml'),
            isNotNull,
          );
        }
        final sourceNotes = await readWhilePumping(tester, () async {
          final repository = await NoteRepository.open(source);
          try {
            expect(repository.formatVersion, 1);
            return await WorkspaceStore(repository).list();
          } finally {
            await repository.close();
          }
        });
        expect(sourceNotes.map((note) => note.id), [original.id]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await readWhilePumping<void>(tester, () async {
          try {
            await controller.flush();
          } finally {
            controller.dispose();
            controllerDisposed = true;
            await controller.repository.close();
          }
        });
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  for (final (label, extension, mainPart) in [
    ('Word 문서 만들기', '.docx', 'word/document.xml'),
    ('프레젠테이션 만들기', '.pptx', 'ppt/slides/slide1.xml'),
    ('한글 문서 만들기', '.hwpx', 'Contents/section0.xml'),
  ]) {
    testWidgets(
      'home creates $extension in the selected folder and reopens its real original',
      (tester) async {
        final folder = (await tester.runAsync(
          () => controller.createFolder('자료'),
        ))!;
        await tester.runAsync(() => controller.openFolder(folder.id));
        await mount(tester);
        await tester.tap(find.byKey(const ValueKey('library-create-button')));
        await tester.pumpAndSettle();
        expect(find.text(label), findsOneWidget);
        await tester.ensureVisible(find.text(label));
        await tester.runAsync(() async => tester.tap(find.text(label)));
        await drain(tester);
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '발표 & 정리',
        );
        await tester.runAsync(() async => tester.tap(find.text('확인')));
        for (
          var i = 0;
          i < 20 && find.byType(OfficeWorkspace).evaluate().isEmpty;
          i++
        ) {
          await drain(tester);
        }
        final note = controller.activeSession!.note;
        expect(note.folderId, folder.id);
        expect(note.documentKind, VaultDocumentKind.office);
        final edition = await readWhilePumping(
          tester,
          () => OfficeDocumentStore(controller.repository).readLatest(note),
        );
        expect(edition.originalFileName, endsWith(extension));
        final original = ZipDecoder().decodeBytes(edition.originalBytes);
        expect(original.findFile(mainPart), isNotNull);
        final back = find
            .ancestor(
              of: find.byTooltip('문서 목록으로').last,
              matching: find.byType(IconButton),
            )
            .first;
        for (
          var i = 0;
          i < 40 && tester.widget<IconButton>(back).onPressed == null;
          i++
        ) {
          await drain(tester);
        }
        expect(
          tester.widget<IconButton>(back).onPressed,
          isNotNull,
          reason: 'error=${controller.error}; dirty=${controller.dirty}',
        );
        await tester.runAsync(
          () async => tester.tap(find.byTooltip('문서 목록으로').last),
        );
        for (
          var i = 0;
          i < 20 && find.byType(LibraryHome).evaluate().isEmpty;
          i++
        ) {
          await drain(tester);
        }
        expect(
          find.byType(LibraryHome),
          findsOneWidget,
          reason:
              'active=${controller.activeSession?.note.id}; dirty=${controller.dirty}; error=${controller.error}; spinners=${find.byType(LinearProgressIndicator).evaluate().length}; drawer=${tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen}; texts=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
        );
        final home = tester.widget<LibraryHome>(find.byType(LibraryHome));
        await tester.runAsync(() async => home.onOpenNote(home.notes.single));
        await drain(tester);
        expect(find.byType(OfficeWorkspace), findsOneWidget);
        final reopened = await readWhilePumping(
          tester,
          () =>
              OfficeDocumentStore(controller.repository)
                  .readLatest(controller.activeSession!.note),
        );
        expect(reopened.originalBytes, edition.originalBytes);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets(
    'tabs and history switch saved Markdown and folder back reaches its parent',
    (tester) async {
      final folder = await tester.runAsync(
        () => controller.createFolder('Folder'),
      );
      await tester.runAsync(() => controller.openFolder(folder!.id));
      final a = await tester.runAsync(
        () => controller.createNote(
          'A',
          documentKind: VaultDocumentKind.markdown,
        ),
      );
      await tester.runAsync(() async {
        controller.editMarkdown('A content');
        await controller.flush();
        await controller.createNote(
          'B',
          documentKind: VaultDocumentKind.markdown,
        );
      });
      await mount(tester);
      expect(find.byKey(ValueKey('document-tab-${a!.id}')), findsOneWidget);
      await tester.runAsync(() async => tester.tap(find.byTooltip('이전 위치')));
      await drain(tester);
      expect(controller.activeSession!.note.id, a.id);
      expect(controller.markdown, 'A content');
      await tester.runAsync(() async => tester.tap(find.byTooltip('다음 위치')));
      await drain(tester);
      expect(controller.activeSession!.note.title, 'B');
      await tester.runAsync(() async => tester.tap(find.byTooltip('문서 목록으로')));
      await drain(tester);
      expect(controller.currentFolderId, folder!.id);
      await tester.runAsync(tester.binding.handlePopRoute);
      await drain(tester);
      expect(controller.currentFolderId, isNull);
      expect(controller.activeSession, isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'home creates Markdown, back saves it, card reopens its real content',
    (tester) async {
      await mount(tester);
      expect(find.byType(LibraryHome), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('library-create-button')));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Markdown').last);
      });
      await drain(tester);
      for (
        var i = 0;
        i < 10 && find.byType(AlertDialog).evaluate().isEmpty;
        i++
      ) {
        await drain(tester);
      }
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Ideas',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('확인'));
      });
      for (
        var i = 0;
        i < 10 && find.byType(MarkdownEditor).evaluate().isEmpty;
        i++
      ) {
        await drain(tester);
      }
      expect(
        controller.activeSession?.note.documentKind,
        VaultDocumentKind.markdown,
        reason:
            'error=${controller.error}; messages=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
      );
      expect(find.byType(Editor), findsNothing);
      for (
        var i = 0;
        i < 20 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
        i++
      ) {
        await drain(tester);
      }
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        tester.widget<MarkdownEditor>(find.byType(MarkdownEditor)).readOnly,
        isFalse,
      );
      await tester.tap(find.byTooltip('원문 편집'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, '# Tablet ideas');
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('문서 목록으로'));
      });
      await drain(tester);
      for (var i = 0; i < 20 && controller.activeSession != null; i++) {
        await drain(tester);
      }
      expect(controller.activeSession, isNull);
      expect(find.byType(LibraryHome), findsOneWidget);
      expect(find.text('Ideas'), findsWidgets);
      final home = tester.widget<LibraryHome>(find.byType(LibraryHome));
      await tester.runAsync(() async => home.onOpenNote(home.notes.single));
      await drain(tester);
      for (
        var i = 0;
        i < 20 && find.byType(MarkdownEditor).evaluate().isEmpty;
        i++
      ) {
        await drain(tester);
      }
      expect(controller.markdown, '# Tablet ideas');
      expect(find.byType(MarkdownEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

final class _LibraryOfficeConverter extends OfficePreviewEngine {
  new(this.directory, this.output);
  final Directory directory;
  Uint8List output;
  var calls = 0;
  var pageCount = 1;
  Future<void>? waitForResult;

  @override
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) async {
    calls++;
    await waitForResult;
    final pdf = await File('${directory.path}/converted-$sessionId.pdf')
        .writeAsBytes(output);
    final input = await File(sourcePath).readAsBytes();
    return OfficePreviewResult(
      pdfPath: pdf.path,
      pdfSha256: sha256.convert(output).toString(),
      pageCount: pageCount,
      sourceSha256: sha256.convert(input).toString(),
      engineVersion: 'library-test',
    );
  }
}

final class _NoCoverCache extends ThumbnailCache {
  new(super.root);

  @override
  Future<String?> coverKey(NoteRepository repository, VaultNote note) async =>
      null;
}

final class _LibraryTestPaths extends PathProviderPlatform {
  new(this.support, {this.cache});

  final String support;
  final String? cache;

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getTemporaryPath() async => cache;
}
