import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
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
    StudyWorkspace.pendingPdfImport.value = null;
    PdfrxEntryFunctions.instance = originalPdfBackend;
    await c.saveMarkdown();
    await c.repository.close();
    c.dispose();
    await temp.delete(recursive: true);
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
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '새 노트'))
          .onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      if (find.byType(Editor).evaluate().isNotEmpty &&
          tester
              .state<EditorState>(find.byType(Editor))
              .coreInfo
              .filePath
              .isNotEmpty &&
          !c.inkBusy &&
          !c.dirty)
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
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '새 노트'))
          .onPressed!();
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
        StudyWorkspace.pendingPdfImport.value = pdf.path;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      for (var i = 0; i < 30 && !backend.opened; i++) {
        await tester.runAsync(() async {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
      }
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
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() async {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        if (find.textContaining('필기를 열 수 없습니다').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(c.dirty, isTrue);
      expect(find.textContaining('필기를 열 수 없습니다'), findsOneWidget);
      expect(find.text('PDF 가져오기 취소'), findsOneWidget);
      await tester.runAsync(() async {
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'PDF 가져오기 취소'))
            .onPressed!();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      for (var i = 0; i < 30 && c.dirty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
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
  @override
  List<PdfPage> get pages => [TestPdfPage(this)];
  @override
  Future<void> dispose() async {}
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
  bool get isLoaded => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
