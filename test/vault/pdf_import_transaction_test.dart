import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_editor.dart';
import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late WorkspaceController c;
  final originalPdfBackend = PdfrxEntryFunctions.instance;
  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('pdf-transaction-');
    c = WorkspaceController(
      await NoteRepository.open(Directory('${temp.path}/vault')),
    );
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    StudyWorkspace.pendingDocumentImport.value = null;
    PdfrxEntryFunctions.instance = originalPdfBackend;
    await c.saveMarkdown();
    await c.repository.close();
    c.dispose();
    await temp.delete(recursive: true);
  });
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() ready,
    String reason,
  ) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    }
    expect(ready(), isTrue, reason: '$reason\n${c.error}');
  }

  test('disposing a PDF image before its document opens is safe', () async {
    final backend = DelayedPdfBackend();
    PdfrxEntryFunctions.instance = backend;
    final cache = AssetCache();
    final file = File('${temp.path}/slow-image.pdf');
    final document = TestPdfDocument(file.path);
    final image = PdfEditorImage(
      id: 1,
      assetCache: cache,
      pdfBytes: null,
      pdfFile: file,
      pdfPage: 0,
      pageIndex: 0,
      pageSize: const Size(300, 600),
      naturalSize: const Size(300, 600),
      onMoveImage: null,
      onDeleteImage: null,
      onMiscChange: null,
    );

    final loading = image.firstLoad();
    expect(backend.opened, isTrue);
    image.dispose();
    try {
      backend.release.complete(document);
      await expectLater(loading, completes);
      expect(document._disposed, isFalse);
    } finally {
      cache.dispose();
      await Future<void>.delayed(Duration.zero);
    }
    expect(document._disposed, isTrue);
  });

  testWidgets('Android new note closes the library and saves editable ink', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: StudyWorkspace(controller: c),
        ),
      ),
    );
    await tester.pump();
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
    scaffold.openDrawer();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      tester
          .widget<LibraryHome>(find.byType(LibraryHome))
          .onCreate(LibraryCreateAction.handwriting);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (
      var i = 0;
      i < 20 && find.byType(AlertDialog).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '확인'))
          .onPressed!();
    });
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(() async {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      if (find.byType(Editor).evaluate().isNotEmpty &&
          tester
              .state<EditorState>(find.byType(Editor))
              .coreInfo
              .filePath
              .isNotEmpty &&
          !c.inkBusy &&
          !c.dirty &&
          !scaffold.isDrawerOpen)
        break;
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(scaffold.isDrawerOpen, isFalse);
    final editor = tester.state<EditorState>(find.byType(Editor));
    expect(
      tester.widget<Editor>(find.byType(Editor)).workspaceReadOnly,
      isFalse,
    );
    expect(
      editor.coreInfo.readOnly,
      isFalse,
      reason:
          '${editor.coreInfo.readOnlyReason}\n${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join('\n')}',
    );
    await tester.runAsync(() async {
      editor.drawTestStroke();
      await editor.saveToFile();
      await c.flush();
      final saved = await c.loadInk();
      expect(saved.pages.first.strokes, isNotEmpty);
      saved.dispose();
    });
    c.setInkDirty(true);
    scaffold.openDrawer();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('새 폴더'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(scaffold.isDrawerOpen, isFalse);
    expect(find.textContaining('필기 또는 가져오기 작업을 마친 뒤'), findsOneWidget);
    await tester.runAsync(() async {
      c.setInkDirty(false);
      await c.refresh();
    });
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    'failed PDF import can be cancelled without deleting the source or saved ink',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      final backend = DelayedPdfBackend();
      PdfrxEntryFunctions.instance = backend;
      final pdf = File('${temp.path}/broken.pdf');
      final bytes = Uint8List.fromList('synthetic invalid PDF'.codeUnits);
      await tester.runAsync(() => pdf.writeAsBytes(bytes));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: StudyWorkspace(controller: c),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        StudyWorkspace.pendingDocumentImport.value = pdf.path;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await waitFor(tester, () => backend.opened, 'PDF 가져오기가 시작되어야 합니다.');
      expect(
        c.activeSession,
        isNotNull,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join('\n'),
      );
      expect(backend.opened, isTrue);
      final session = c.activeSession!;
      final previous = List<String>.of(session.inkParents);
      backend.release.completeError(StateError('cannot read PDF'));
      await waitFor(
        tester,
        () => find.textContaining('필기를 열 수 없습니다').evaluate().isNotEmpty,
        'PDF 읽기 실패를 표시해야 합니다.',
      );
      expect(c.dirty, isTrue);
      expect(find.textContaining('필기를 열 수 없습니다'), findsOneWidget);
      expect(find.text('PDF 가져오기 취소'), findsOneWidget);
      await tester.runAsync(() async {
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'PDF 가져오기 취소'))
            .onPressed!();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await waitFor(tester, () => !c.dirty, '가져오기 취소가 끝나야 합니다.');
      expect(c.dirty, isFalse);
      expect(session.inkParents, previous);
      expect(await tester.runAsync(pdf.readAsBytes), bytes);
      final restored = await tester.runAsync(() => c.loadInk(session: session));
      expect(restored!.pages, hasLength(1));
      expect(restored.pages.single.isEmpty, isTrue);
      restored.dispose();
      final next = await tester.runAsync(
        () => c.createNote('After cancelled PDF'),
      );
      expect(c.activeSession!.note.id, next!.id);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'delayed PDF import blocks switching, failed first commit retries same pages and bytes',
    (tester) async {
      final backend = DelayedPdfBackend();
      PdfrxEntryFunctions.instance = backend;
      final pdf = File('${temp.path}/source.pdf');
      final originalBytes = Uint8List.fromList(
        '%PDF-synthetic original bytes'.codeUnits,
      );
      await tester.runAsync(() => pdf.writeAsBytes(originalBytes));
      final first = await tester.runAsync(
        () => c.createNote('PDF', importingPdf: true),
      );
      final session = c.activeSession!;
      final other = await tester.runAsync(() => c.store.create('Other'));
      var saves = 0, loaded = false;
      final ids = <List<String>>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Editor(
              path: '/pdf-import-test',
              customTitle: 'Import',
              pdfPath: pdf.path,
              workspaceReadOnly: true,
              loadSnapshot: () async =>
                  EditorCoreInfo(filePath: '/pdf-import-test')
                    ..pages.add(EditorPage()),
              onBusyChanged: (v) => c.setInkBusy(v, session: session),
              onDirtyChanged: (v) => c.setInkDirty(v, session: session),
              onLoaded: (_) => loaded = true,
              onSaveSnapshot: (core, page) async {
                ids.add(core.pages.map((p) => p.pageId).toList());
                if (++saves == 1)
                  throw const FileSystemException('first commit failed');
                await c.saveInk(core, page, session: session);
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(loaded, isFalse);
      await expectLater(c.openNote(other!), throwsStateError);
      backend.release.complete(TestPdfDocument(pdf.path));
      await tester.pump();
      await tester.pump();
      expect(loaded, isFalse);
      expect(c.dirty, isTrue);
      expect(find.textContaining('기기 저장 실패'), findsOneWidget);
      final editor = tester.state<EditorState>(find.byType(Editor));
      await tester.runAsync(editor.saveToFile);
      expect(loaded, isTrue);
      expect(editor.coreInfo.readOnly, isTrue);
      expect(ids, hasLength(2));
      expect(ids[1], ids[0]);
      final heads = await tester.runAsync(
        () => c.repository.heads(first!.inkEntityId),
      );
      final files = await tester.runAsync(
        () => c.repository.readFiles(heads!.single),
      );
      expect(files!['main.sbn2.0'], originalBytes);
      expect(c.dirty, isFalse);
      await tester.runAsync(() => c.openNote(other));
      await tester.runAsync(
        () => expectLater(
          c.saveInk(editor.coreInfo, 0, session: session),
          throwsStateError,
        ),
      );
      expect(
        await tester.runAsync(() => c.repository.heads(other.inkEntityId)),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class DelayedPdfBackend implements PdfrxEntryFunctions {
  final release = Completer<PdfDocument>();
  var opened = false;
  @override
  Future<PdfDocument> openFile(
    String filePath, {
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
  }) {
    opened = true;
    return release.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestPdfDocument extends PdfDocument {
  new(String path) : super(sourceName: path);
  final _events = StreamController<PdfDocumentEvent>.broadcast();
  late final _pages = List<PdfPage>.unmodifiable([TestPdfPage(this)]);
  var _disposed = false;
  @override
  Stream<PdfDocumentEvent> get events => _events.stream;
  @override
  PdfPermissions? get permissions => null;
  @override
  bool get isEncrypted => false;
  @override
  List<PdfPage> get pages => _pages;
  @override
  bool isIdenticalDocumentHandle(Object? other) => identical(this, other);
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    unawaited(_events.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestPdfPage implements PdfPage {
  new(this.document);
  @override
  final PdfDocument document;
  @override
  int get pageNumber => 1;
  @override
  double get width => 300;
  @override
  double get height => 600;
  @override
  PdfPageRotation get rotation => PdfPageRotation.none;
  @override
  bool get isLoaded => true;
  @override
  PdfPageRenderCancellationToken createCancellationToken() =>
      _TestPdfRenderCancellationToken();
  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = PdfPageRenderFlags.none,
    PdfPageRenderCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCanceled ?? false) return null;
    final w = width ?? (fullWidth ?? this.width).round();
    final h = height ?? (fullHeight ?? this.height).round();
    return PdfImage.createFromBgraData(
      Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255),
      width: w,
      height: h,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestPdfRenderCancellationToken extends PdfPageRenderCancellationToken {
  var _cancelled = false;
  @override
  bool get isCanceled => _cancelled;
  @override
  void cancel() => _cancelled = true;
}
