import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:pdfrx/pdfrx.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';
import 'package:sbn/tool_id.dart';

import '../office/office_original_preview_test.dart'
    show
        officePreviewPdf,
        officePreviewPdfiumAvailable,
        officePreviewUntil,
        withOfficePreviewPdfium;
import '../utils/test_mock_channel_handlers.dart';
import 'pdf_import_transaction_test.dart'
    show DelayedPdfBackend, TestPdfDocument;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  final oldBackend = PdfrxEntryFunctions.instance;
  late Directory temp;
  late NoteRepository repository;
  final controllers = <WorkspaceController>[];
  final extraRepositories = <NoteRepository>[];
  final original = Uint8List.fromList(
    '%PDF-restart-source-with-original-bytes'.codeUnits,
  );
  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('pdf-restart-widget-');
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
  });
  tearDown(() async {
    PdfrxEntryFunctions.instance = oldBackend;
    debugDefaultTargetPlatformOverride = null;
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
    for (final repo in extraRepositories) {
      await repo.close();
    }
    extraRepositories.clear();
    await repository.close();
    await temp.delete(recursive: true);
  });
  WorkspaceController control(NoteRepository repo) {
    final c = WorkspaceController(repo);
    controllers.add(c);
    return c;
  }

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
    }
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<T> io<T>(WidgetTester tester, Future<T> Function() operation) async {
    var done = false;
    T? result;
    Object? error;
    StackTrace? stack;
    await tester.runAsync(() async {
      operation()
          .timeout(const Duration(seconds: 15))
          .then(
            (value) {
              result = value;
              done = true;
            },
            onError: (Object e, StackTrace s) {
              error = e;
              stack = s;
              done = true;
            },
          );
    });
    for (var i = 0; i < 100 && !done; i++) {
      await drain(tester);
    }
    expect(done, isTrue);
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return result as T;
  }

  Future<void> mount(WidgetTester tester, WorkspaceController c) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: StudyWorkspace(controller: c)),
      ),
    );
    await drain(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets(
    'fresh app resumes canonical PDF and its first saved snapshot reopens without reimport',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final backend = _RestartPdfBackend();
      PdfrxEntryFunctions.instance = backend;
      try {
        final note = await io(
          tester,
          () => WorkspaceStore(repository).createWithSource(
            '재시작 PDF',
            fileName: 'original.pdf',
            bytes: original,
            documentKind: VaultDocumentKind.pdf,
          ),
        );
        final reopened = await io(
          tester,
          () => NoteRepository.open(repository.root),
        );
        extraRepositories.add(reopened);
        final c = control(reopened);
        final recoveredNote = (await io(tester, c.store.list)).single;
        await io(tester, () => c.openNote(recoveredNote));
        await mount(tester, c);
        for (var i = 0; i < 40 && !backend.opened; i++) {
          await drain(tester);
        }
        expect(backend.opened, isTrue);
        expect(
          tester.widget<Editor>(find.byType(Editor)).pdfPath,
          c.pendingPdfPath,
        );
        backend.release.complete(TestPdfDocument(c.pendingPdfPath!));
        for (var i = 0; i < 60 && c.dirty; i++) {
          await drain(tester);
        }
        expect(
          c.dirty,
          isFalse,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((text) => text.data)
              .join('\n'),
        );
        final session = c.activeSession!;
        final saved = await io(
          tester,
          () async => reopened.readFiles(
            (await reopened.heads(note.inkEntityId)).single,
          ),
        );
        expect(
          saved.values.any(
            (bytes) =>
                bytes.length == original.length && listEquals(bytes, original),
          ),
          isTrue,
        );
        final marker =
            jsonDecode(utf8.decode(saved['pdf-import.json']!)) as Map;
        expect(marker['sourceEntityId'], note.sourceEntityId);
        final ids = List.of(session.inkParents);
        await unmount(tester);
        final nextRepo = await io(
          tester,
          () => NoteRepository.open(repository.root),
        );
        extraRepositories.add(nextRepo);
        final next = control(nextRepo);
        final nextNote = (await io(tester, next.store.list)).single;
        await io(tester, () => next.openNote(nextNote));
        expect(next.pendingPdfPath, isNull);
        expect(next.pdfImportError, isNull);
        expect(next.activeSession!.inkParents, ids);
        await mount(tester, next);
        for (var i = 0; i < 30 && find.byType(Editor).evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(tester.widget<Editor>(find.byType(Editor)).pdfPath, isNull);
        final core = await io(tester, next.loadInk);
        expect(
          core.pages.any((page) => page.backgroundImage is PdfEditorImage),
          isTrue,
        );
        core.dispose();
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
        debugDefaultTargetPlatformOverride = null;
        await io(tester, () async {
          for (final c in controllers) {
            c.dispose();
          }
          controllers.clear();
          for (final repo in extraRepositories) {
            await repo.close();
          }
          extraRepositories.clear();
        });
      }
    },
  );

  testWidgets(
    'Windows views incoming PDF without making ink and opens the Android ink when it arrives',
    (tester) => withOfficePreviewPdfium(tester, () async {
      final oldPlatform = debugDefaultTargetPlatformOverride;
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final receiver = await io(
        tester,
        () => NoteRepository.open(
          Directory('${temp.path}/windows'),
          vaultId: repository.vaultId,
          createFormatVersion: 2,
        ),
      );
      extraRepositories.add(receiver);
      expect(receiver.deviceId, isNot(repository.deviceId));
      final remote = _PdfRoundTripRemote(repository.vaultId);
      final ownerSync = SyncCoordinator(
        repository: repository,
        remote: remote,
        stateDirectory: Directory('${temp.path}/android-drive'),
      );
      final receiverSync = SyncCoordinator(
        repository: receiver,
        remote: remote,
        stateDirectory: Directory('${temp.path}/windows-drive'),
      );
      EditorCoreInfo? ownerInk;
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await io(
          tester,
          () => FileManager.init(
            documentsDirectory: '${temp.path}/android-working',
            shouldWatchRootDirectory: false,
          ),
        );
        final owner = control(repository);
        final pdf = await io(tester, () => officePreviewPdf(PdfColors.blue));
        final note = await io(
          tester,
          () => owner.importPdf('Peer PDF', fileName: 'peer.pdf', bytes: pdf),
        );
        final seed = (await io(
          tester,
          () => repository.heads(note.inkEntityId),
        )).single;
        final seedFiles = await io(tester, () => repository.readFiles(seed));
        expect(seedFiles.keys, ['main.sbn2']);
        final core = await io(tester, owner.loadInk);
        ownerInk = core;
        const size = Size(
          EditorPage.defaultWidth,
          EditorPage.defaultWidth * 1.5,
        );
        final page = EditorPage(
          size: size,
          backgroundImage: PdfEditorImage(
            id: core.nextImageId++,
            assetCache: core.assetCache,
            pdfBytes: null,
            pdfFile: File(owner.pendingPdfPath!),
            pdfPage: 0,
            pageIndex: 0,
            pageSize: size,
            naturalSize: const Size(200, 300),
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          ),
        );
        const points = [Offset(32, 40), Offset(58, 68), Offset(85, 75)];
        page.strokes.add(
          Stroke(
            color: Colors.black,
            pressureEnabled: false,
            options: StrokeOptions(size: 4, thinning: 0),
            pageIndex: 0,
            page: page,
            toolId: ToolId.ballpointPen,
          )..addPoints(points),
        );
        core.pages.insert(0, page);
        final pageIds = core.pages.map((page) => page.pageId).toList();

        await io(tester, () async {
          await ownerSync.syncOnce();
          await receiverSync.syncOnce();
          await FileManager.init(
            documentsDirectory: '${temp.path}/windows-working',
            shouldWatchRootDirectory: false,
          );
        });
        Future<List<String>> receiverInkIds() async => [
          for (final row in await receiver.revisions())
            if (row.entityId == note.inkEntityId) row.revisionId,
        ];
        expect(await io(tester, receiverInkIds), [seed.revisionId]);

        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final windows = control(receiver);
        await io(tester, windows.refresh);
        await mount(tester, windows);
        final received = find.byKey(
          ValueKey('library-note-${note.revision.revisionId}'),
        );
        await tester.tap(received);
        final editor = find.byType(Editor);
        EditorState state() => tester.state<EditorState>(editor);
        await officePreviewUntil(
          tester,
          () =>
              editor.evaluate().length == 1 &&
              state().coreInfo.pages.firstOrNull?.backgroundImage
                  is PdfEditorImage &&
              !windows.inkBusy,
          'The real Windows editor should open the received PDF',
        );
        expect(
          await io(tester, receiverInkIds),
          [seed.revisionId],
          reason: 'Viewing the partial peer import must not publish local ink',
        );
        expect(state().coreInfo.readOnly, isTrue);
        expect(windows.dirty, isFalse);
        const previewMessage =
            '다른 기기의 첫 필기 판본을 기다리는 중입니다. 지금은 PDF를 읽기 전용으로 볼 수 있습니다.';
        expect(find.text(previewMessage), findsOneWidget);
        expect(find.text('이 기기에서 필기 시작'), findsOneWidget);
        expect(find.textContaining('필기 편집은 Android에서'), findsNothing);

        final annotated = await io(tester, () async {
          await owner.saveInk(core, 0);
          final head = (await repository.heads(note.inkEntityId)).single;
          await ownerSync.syncOnce();
          await receiverSync.syncOnce();
          return head;
        });
        await officePreviewUntil(
          tester,
          () =>
              editor.evaluate().length == 1 &&
              state().coreInfo.pages.firstOrNull?.pageId == page.pageId &&
              !windows.inkBusy,
          'The open Windows editor should switch to the Android ink snapshot',
        );
        final shown = state().coreInfo.pages;
        expect(shown.map((page) => page.pageId), pageIds);
        expect(shown.first.backgroundImage, isA<PdfEditorImage>());
        expect(shown.first.strokes.single.toolId, ToolId.ballpointPen);
        expect(
          shown.first.strokes.single.points.map((p) => Offset(p.x, p.y)),
          points,
        );
        expect(state().coreInfo.readOnly, isFalse);
        expect(find.text(previewMessage), findsNothing);
        expect(find.text('이 기기에서 필기 시작'), findsNothing);
        expect(windows.remoteConflict, isFalse);
        expect(
          await io(tester, receiverInkIds),
          unorderedEquals([seed.revisionId, annotated.revisionId]),
        );
        final onReceiver = await io(
          tester,
          () => receiver.readFiles(annotated),
        );
        expect(
          onReceiver.values.any((bytes) => listEquals(bytes, pdf)),
          isTrue,
        );

        final markdown = find.byType(MarkdownEditor);
        Finder markdownControl(Finder child) =>
            find.descendant(of: markdown, matching: child);
        await tester.tap(markdownControl(find.byTooltip('원문 편집')));
        await tester.pump();
        const summary = '# Windows 정리\n\nAndroid 필기를 보며 정리했습니다.';
        await tester.enterText(
          markdownControl(find.byType(TextField)),
          summary,
        );
        await tester.pump();
        await tester.tap(markdownControl(find.byTooltip('Markdown 저장')));
        await officePreviewUntil(
          tester,
          () => !windows.markdownDirty,
          'The Markdown typed in the Windows workspace should save',
        );
        final returned = await io(tester, () async {
          await receiverSync.syncOnce();
          await ownerSync.syncOnce();
          return (await WorkspaceStore(repository).open(note)).readMarkdown();
        });
        expect(returned, summary);
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
        ownerInk?.dispose();
        debugDefaultTargetPlatformOverride = oldPlatform;
        await io(tester, () async {
          await receiverSync.close();
          await ownerSync.close();
          remote.close();
          for (final c in controllers) {
            c.dispose();
          }
          controllers.clear();
          await receiver.close();
          extraRepositories.remove(receiver);
          await repository.close();
        });
      }
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  test('unmarked user ink survives cancellation and process restart before canonical PDF resume', () async {
    final note = await WorkspaceStore(repository).createWithSource(
      '기존 메모',
      fileName: 'original.pdf',
      bytes: original,
      documentKind: VaultDocumentKind.pdf,
    );
    final core = EditorCoreInfo(filePath: '/pdf-existing-user-ink')
      ..pages.add(EditorPage());
    core.pages.single.quill.controller.document.insert(0, '보존할 필기 내용');
    final pageId = core.pages.single.pageId;
    final snapshot = await SaberInkAdapter.capture(core, 0);
    core.dispose();
    await (await WorkspaceStore(repository).open(note)).saveInk(snapshot);
    final c = control(repository);
    await c.openNote(note);
    final loaded = await c.loadInk();
    expect(loaded.pages.first.pageId, pageId);
    expect(
      loaded.pages.first.quill.controller.document.toPlainText(),
      contains('보존할 필기 내용'),
    );
    expect(loaded.pages.last.isEmpty, isTrue);
    loaded.dispose();
    final before = List.of(c.activeSession!.inkParents);
    await c.cancelPendingImport(session: c.activeSession!);
    final nextRepo = await NoteRepository.open(repository.root);
    extraRepositories.add(nextRepo);
    final next = control(nextRepo);
    await next.openNote((await next.store.list()).single);
    final resumed = await next.loadInk();
    expect(resumed.pages.first.pageId, pageId);
    expect(
      resumed.pages.first.quill.controller.document.toPlainText(),
      contains('보존할 필기 내용'),
    );
    expect(next.activeSession!.inkParents, before);
    resumed.dispose();
  });
}

class _PdfRoundTripRemote implements RemoteStore {
  @override
  final String vaultId;
  final _records = <String, RevisionRecord>{};
  final _blobs = <String, Uint8List>{};
  var _nextId = 0;

  new(this.vaultId);

  @override
  String get remoteId => 'pdf-round-trip';

  @override
  Future<String> generateId() async => 'file-${_nextId++}';

  @override
  Future<String?> findBlob(BlobRef ref) async =>
      _blobs.containsKey(ref.hash) ? ref.hash : null;

  @override
  Future<void> putBlob(
    BlobRef ref,
    Uint8List bytes,
    String intentFileId,
  ) async {
    _blobs.putIfAbsent(ref.hash, () => Uint8List.fromList(bytes));
  }

  @override
  Future<void> publishRevision(
    RevisionRecord record,
    String intentFileId,
  ) async {
    _records.putIfAbsent(intentFileId, () => record);
  }

  @override
  Future<RevisionRecord> readManifest(String fileId) async =>
      _records[fileId] ?? (throw RemoteException.missing('Missing revision'));

  @override
  Future<Uint8List> readBlob(BlobRef ref) async =>
      _blobs[ref.hash] ?? (throw RemoteException.missing('Missing blob'));

  @override
  Future<String> startPageToken() async => '${_records.length}';

  @override
  Future<RemotePage> listManifests({String? pageToken}) async =>
      RemotePage(_records.keys.map(RemoteChange.new).toList());

  @override
  Future<RemotePage> readChanges(String pageToken) async => RemotePage(
    _records.keys.skip(int.parse(pageToken)).map(RemoteChange.new).toList(),
    newStartPageToken: '${_records.length}',
  );

  @override
  void close() {}
}

class _RestartPdfBackend extends DelayedPdfBackend {
  var _opens = 0;
  @override
  Future<PdfDocument> openFile(
    String filePath, {
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
  }) {
    opened = true;
    if (_opens++ == 0) return release.future;
    return Future.value(TestPdfDocument(filePath));
  }
}
