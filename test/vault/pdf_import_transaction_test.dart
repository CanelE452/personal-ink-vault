import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:saber/pages/workspace/workspace_controller.dart';

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
    PdfrxEntryFunctions.instance = originalPdfBackend;
    await c.saveMarkdown();
    await c.repository.close();
    c.dispose();
    await temp.delete(recursive: true);
  });
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
  @override
  Future<PdfDocument> openFile(
    String filePath, {
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
  }) => release.future;
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
