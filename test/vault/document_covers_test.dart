import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

class _UnavailablePreview extends OfficePreviewEngine {
  new() : super(isWindows: true, isAndroid: false);

  var calls = 0;
  @override
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) async {
    calls++;
    expect(await File(sourcePath).readAsBytes(), [1, 2, 3]);
    return null;
  }
}

class _PdfPreview extends OfficePreviewEngine {
  final Uint8List pdf;
  var calls = 0;
  new(this.pdf) : super(isWindows: true, isAndroid: false);
  @override
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) async {
    calls++;
    final source = File(sourcePath);
    final output = await File('${source.parent.path}/preview.pdf')
        .writeAsBytes(pdf);
    return OfficePreviewResult(
      pdfPath: output.path,
      pdfSha256: sha256.convert(pdf).toString(),
      pageCount: 1,
      sourceSha256: sha256.convert(await source.readAsBytes()).toString(),
      engineVersion: 'test-preview',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  late Directory temp;
  late NoteRepository repository;
  late WorkspaceStore store;
  late ThumbnailCache cache;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('document-covers-');
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    store = WorkspaceStore(repository);
    cache = ThumbnailCache(Directory('${temp.path}/covers'));
  });
  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  Future<RevisionRecord> body(
    VaultNote note,
    String name,
    Object json, {
    List<String> parents = const [],
  }) => repository.commit(
    entityId: note.inkEntityId,
    kind: EntityKind.ink,
    ownerNoteId: note.id,
    files: {name: Uint8List.fromList(utf8.encode(jsonEncode(json)))},
    parentRevisionIds: parents,
  );

  Future<int> contentPixels(
    File file, {
    bool redOnly = false,
    bool blueOnly = false,
  }) async {
    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    try {
      final image = (await codec.getNextFrame()).image;
      try {
        expect(image.width, 240);
        expect(image.height, lessThanOrEqualTo(320));
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        var count = 0;
        for (var i = 0; i < data.length; i += 4) {
          if (blueOnly
              ? data[i] < 100 &&
                    data[i + 1] < 200 &&
                    data[i + 2] > 180 &&
                    data[i + 2] > data[i + 1] + 50
              : redOnly
              ? data[i] > 150 && data[i + 1] < 100 && data[i + 2] < 100
              : data[i] < 150 && data[i + 1] < 150 && data[i + 2] < 150)
            count++;
        }
        return count;
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  testWidgets(
    'Markdown uses saved body, reuses cache, and invalidates on its relevant revision',
    (tester) async {
      await tester.runAsync(() async {
        final note = await store.create(
          'Untitled',
          documentKind: VaultDocumentKind.markdown,
        );
        final session = await store.open(note);
        await session.saveMarkdown(
          '# Body heading\n\nA representative paragraph from the saved document.',
        );
        final before = (await repository.revisions()).length;
        final key = await cache.coverKey(repository, note);
        expect(key, isNotNull);
        final first = await cache.getOrCreate(repository, note);
        expect(first, isNotNull);
        expect(await contentPixels(first!), greaterThan(200));
        await first.setLastModified(DateTime(2000));
        expect(
          (await cache.getOrCreate(repository, note))!.lastModifiedSync().year,
          2000,
        );
        await session.saveMarkdown('# Different saved body\nThe next edition.');
        expect(await cache.coverKey(repository, note), isNot(key));
        expect(
          (await cache.getOrCreate(repository, note))!.path,
          isNot(first.path),
        );
        expect((await repository.revisions()).length, before + 1);
      });
    },
  );

  testWidgets(
    'typed canvas, page and database bodies produce representative, distinct covers without source changes',
    (tester) async {
      await tester.runAsync(() async {
        final canvas = const CardCanvasDocument.empty().copyWith(
          nodes: [
            CardCanvasNode.text(
              id: 'body',
              text: 'Saved canvas idea',
              x: -400,
              y: -300,
            ),
          ],
        );
        final page = const BlockPageDocument.empty().copyWith(
          blocks: [
            BlockPageBlock.create(type: 'heading1', text: 'Saved block title'),
            BlockPageBlock.create(text: 'The block document body.'),
          ],
        );
        var db = WorkspaceDatabase.empty();
        db = db.addRow(
          DatabaseRow.create(
            values: {db.properties.first.id: 'Saved row content'},
          ),
        );
        final bytes = <String>{};
        for (final item in [
          (VaultDocumentKind.canvas, 'board.canvas', canvas.toJson()),
          (VaultDocumentKind.page, 'page.json', page.toJson()),
          (VaultDocumentKind.database, 'database.json', db.toJson()),
        ]) {
          final note = await store.create('Untitled', documentKind: item.$1);
          final revision = await body(note, item.$2, item.$3);
          final original = await repository.readFiles(revision);
          final count = (await repository.revisions()).length;
          final file = await cache.getOrCreate(repository, note);
          expect(file, isNotNull, reason: item.$1.name);
          expect(
            await contentPixels(file!),
            greaterThan(100),
            reason: item.$1.name,
          );
          bytes.add(base64Encode(await file.readAsBytes()));
          expect(await repository.readFiles(revision), original);
          expect((await repository.revisions()).length, count);
        }
        expect(bytes.length, 3);
      });
    },
  );

  testWidgets(
    'infinite cover fits saved negative-coordinate ink instead of a blank origin',
    (tester) async {
      await tester.runAsync(() async {
        final note = await store.create(
          'Infinite',
          documentKind: VaultDocumentKind.infinite,
        );
        await body(
          note,
          'infinite.json',
          InfiniteDocument(
            strokes: [
              InfiniteStroke(
                id: 'negative',
                tool: InfiniteInkTool.pen,
                color: 0xffff0000,
                width: 20,
                points: const [
                  InfinitePoint(-1200, -900),
                  InfinitePoint(-700, -500),
                ],
              ),
            ],
          ).toJson(),
        );
        final file = await cache.getOrCreate(repository, note);
        expect(file, isNotNull);
        expect(await contentPixels(file!, redOnly: true), greaterThan(100));
      });
    },
  );

  test('Office original-only preview is read-only, serialized, and cleaned after an unavailable renderer', () async {
    final note = await OfficeDocumentStore(repository).importDocument(
      title: 'Office',
      fileName: 'saved.docx',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    final source = (await repository.heads(note.sourceEntityId!)).single;
    final original = await repository.readFiles(source);
    final before = (await repository.revisions()).length;
    final engine = _UnavailablePreview();
    cache = ThumbnailCache(
      Directory('${temp.path}/office-covers'),
      officePreviewEngine: engine,
    );
    expect(await cache.coverKey(repository, note), isNotNull);
    expect(
      await Future.wait([
        cache.getOrCreate(repository, note),
        cache.getOrCreate(repository, note),
      ]),
      [null, null],
    );
    expect(engine.calls, 1);
    expect(await repository.readFiles(source), original);
    expect((await repository.revisions()).length, before);
    expect(
      await cache.root
          .list(recursive: true)
          .where((file) => file.path.endsWith('.docx'))
          .toList(),
      isEmpty,
    );
  });

  test(
    'Android original-only PPTX covers never open an Office preview',
    () async {
      const channel = MethodChannel('personal_ink_vault/office_engine');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return {'status': 'cancelled'};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final engine = OfficePreviewEngine(
        androidEngine: const AndroidOfficeEngine(isAndroid: true),
        isAndroid: true,
        isWindows: false,
      );
      final starter = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'Slides',
      );
      final note = await OfficeDocumentStore(repository).importDocument(
        title: 'Slides',
        fileName: starter.fileName,
        bytes: starter.bytes,
      );
      final before = (await repository.revisions()).length;
      final covers = Directory('${temp.path}/android-office-covers');
      cache = ThumbnailCache(covers, officePreviewEngine: engine);
      expect(await cache.getOrCreate(repository, note), isNull);
      // Reopening the library can recreate the cache.
      cache = ThumbnailCache(covers, officePreviewEngine: engine);
      expect(await cache.getOrCreate(repository, note), isNull);
      expect(calls, isEmpty);
      expect((await repository.revisions()).length, before);

      final source = await File('${temp.path}/${starter.fileName}')
          .writeAsBytes(starter.bytes);
      expect(
        await engine.preview(
          sourcePath: source.absolute.path,
          sessionId: 'test-annotation',
        ),
        isNull,
      );
      expect(calls, ['preview'], reason: 'Explicit preview still opens Office');
    },
  );

  testWidgets(
    'Office renders original-only previews and exact paired PDF editions without canonical cover revisions',
    (tester) async {
      await tester.runAsync(() async {
        final previous = Pdfrx.pdfiumModulePath;
        Pdfrx.pdfiumModulePath = File(
          'build/windows/x64/runner/Release/pdfium.dll',
        ).absolute.path;
        try {
          await pdfrxInitialize(tmpPath: temp.path);
          final pdf = pw.Document()
            ..addPage(
              pw.Page(
                pageFormat: const PdfPageFormat(200, 300),
                margin: pw.EdgeInsets.zero,
                build: (_) =>
                    pw.Container(width: 200, height: 300, color: PdfColors.red),
              ),
            );
          final bytes = await pdf.save();
          final engine = _PdfPreview(bytes);
          cache = ThumbnailCache(
            Directory('${temp.path}/office-native'),
            officePreviewEngine: engine,
          );
          final starter = OfficeTemplates.create(
            OfficeTemplateKind.document,
            title: 'Saved document',
          );
          final documents = OfficeDocumentStore(repository);
          final note = await documents.importDocument(
            title: 'Office',
            fileName: starter.fileName,
            bytes: starter.bytes,
          );
          final original = (await repository.heads(note.sourceEntityId!))
              .single;
          final canonical = await repository.readFiles(original);
          final count = (await repository.revisions()).length;
          final key = await cache.coverKey(repository, note);
          final first = await cache.getOrCreate(repository, note);
          expect(first, isNotNull);
          expect(await contentPixels(first!, redOnly: true), greaterThan(1000));
          expect(engine.calls, 1);
          expect(await repository.readFiles(original), canonical);
          expect((await repository.revisions()).length, count);
          expect(
            await cache.root
                .list(recursive: true)
                .where(
                  (entry) =>
                      entry.path.endsWith('.docx') ||
                      entry.path.endsWith('.pdf'),
                )
                .toList(),
            isEmpty,
          );
          final edit = await documents.beginEdit(note);
          await documents.commitEdited(
            edit,
            originalBytes: starter.bytes,
            pdfBytes: bytes,
            engineVersion: 'saved-edition',
            pageCount: 1,
          );
          expect(await cache.coverKey(repository, note), isNot(key));
          final paired = await cache.getOrCreate(repository, note);
          expect(paired, isNotNull);
          expect(paired!.path, isNot(first.path));
          expect(await contentPixels(paired, redOnly: true), greaterThan(1000));
          expect(
            engine.calls,
            1,
            reason: 'A bound PDF edition needs no Office conversion',
          );
          final androidCache = ThumbnailCache(
            Directory('${temp.path}/office-bound-pdf-android'),
            officePreviewEngine: OfficePreviewEngine(
              androidEngine: const AndroidOfficeEngine(isAndroid: true),
              isAndroid: true,
              isWindows: false,
            ),
          );
          final androidCover = await androidCache.getOrCreate(repository, note);
          expect(androidCover, isNotNull);
          expect(
            await contentPixels(androidCover!, redOnly: true),
            greaterThan(1000),
          );
          expect((await repository.revisions()).length, count + 1);
        } finally {
          Pdfrx.pdfiumModulePath = previous;
        }
      });
    },
    skip:
        !Platform.isWindows ||
        !File('build/windows/x64/runner/Release/pdfium.dll').existsSync(),
  );

  testWidgets(
    'Office annotation head invalidates its exact edition cover and renders saved PDF ink; conflicts fall back',
    (tester) async {
      await tester.runAsync(() async {
        await FileManager.init(shouldWatchRootDirectory: false);
        final previous = Pdfrx.pdfiumModulePath;
        Pdfrx.pdfiumModulePath = File(
          'build/windows/x64/runner/Release/pdfium.dll',
        ).absolute.path;
        try {
          await pdfrxInitialize(tmpPath: temp.path);
          final pdf = pw.Document()
            ..addPage(
              pw.Page(
                pageFormat: const PdfPageFormat(200, 300),
                margin: pw.EdgeInsets.zero,
                build: (_) =>
                    pw.Container(width: 200, height: 300, color: PdfColors.red),
              ),
            );
          final bytes = await pdf.save();
          final starter = OfficeTemplates.create(
            OfficeTemplateKind.document,
            title: 'Annotated document',
          );
          final documents = OfficeDocumentStore(repository);
          final note = await documents.importDocument(
            title: 'Office',
            fileName: starter.fileName,
            bytes: starter.bytes,
          );
          final edition = await documents.commitEdited(
            await documents.beginEdit(note),
            originalBytes: starter.bytes,
            pdfBytes: bytes,
            engineVersion: 'saved-edition',
            pageCount: 1,
          );
          final canonical = await repository.readFiles(edition.revision);
          final beforeKey = await cache.coverKey(repository, note);
          final beforeCover = (await cache.getOrCreate(repository, note))!;
          expect(await contentPixels(beforeCover, blueOnly: true), 0);
          final core = EditorCoreInfo(filePath: '/office-cover-test')
            ..backgroundColor = Colors.white
            ..backgroundPattern = .none;
          final page = EditorPage(size: const Size(1000, 1400));
          core.pages.add(page);
          page.backgroundImage = PdfEditorImage(
            id: 0,
            assetCache: core.assetCache,
            pdfBytes: bytes,
            pdfFile: null,
            pdfPage: 0,
            pageIndex: 0,
            pageSize: page.size,
            naturalSize: const Size(200, 300),
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          );
          page.strokes.add(
            Stroke(
              color: Colors.blue,
              pressureEnabled: false,
              options: StrokeOptions(size: 50, thinning: 0),
              pageIndex: 0,
              page: page,
              toolId: ToolId.ballpointPen,
            )..addPoints(const [Offset(100, 100), Offset(900, 100)]),
          );
          try {
            final annotation = await OfficeAnnotationStore(repository)
                .open(note, edition);
            await annotation.saveSnapshot(core, 0);
            final count = (await repository.revisions()).length;
            expect(await cache.coverKey(repository, note), isNot(beforeKey));
            final cover = await cache.getOrCreate(repository, note);
            expect(cover, isNotNull);
            expect(cover!.path, isNot(beforeCover.path));
            expect(
              await contentPixels(cover, blueOnly: true),
              greaterThan(100),
            );
            expect(
              await contentPixels(cover, redOnly: true),
              greaterThan(1000),
            );
            expect(await repository.readFiles(edition.revision), canonical);
            expect((await repository.revisions()).length, count);
            await repository.commit(
              entityId: edition.bindingId!,
              kind: EntityKind.ink,
              ownerNoteId: note.id,
              files: await SaberInkAdapter.capture(core, 0),
              parentRevisionIds: [],
            );
            expect(await cache.coverKey(repository, note), isNull);
            expect(await cache.getOrCreate(repository, note), isNull);
          } finally {
            core.dispose();
          }
        } finally {
          Pdfrx.pdfiumModulePath = previous;
        }
      });
    },
    skip:
        !Platform.isWindows ||
        !File('build/windows/x64/runner/Release/pdfium.dll').existsSync(),
  );

  testWidgets(
    'Office derived cover uses the saved PDF and its ink until variants are ambiguous',
    (tester) async {
      await tester.runAsync(() async {
        await FileManager.init(shouldWatchRootDirectory: false);
        final previous = Pdfrx.pdfiumModulePath;
        Pdfrx.pdfiumModulePath = File(
          'build/windows/x64/runner/Release/pdfium.dll',
        ).absolute.path;
        try {
          await pdfrxInitialize(tmpPath: temp.path);
          Future<Uint8List> pdfBytes(PdfColor color) {
            final pdf = pw.Document()
              ..addPage(
                pw.Page(
                  pageFormat: const PdfPageFormat(200, 300),
                  margin: pw.EdgeInsets.zero,
                  build: (_) =>
                      pw.Container(width: 200, height: 300, color: color),
                ),
              );
            return pdf.save();
          }

          final red = await pdfBytes(PdfColors.red);
          final green = await pdfBytes(PdfColors.green);
          final engine = _PdfPreview(green);
          cache = ThumbnailCache(
            Directory('${temp.path}/derived-covers'),
            officePreviewEngine: engine,
          );
          final starter = OfficeTemplates.create(
            OfficeTemplateKind.document,
            title: 'Derived cover',
          );
          final documents = OfficeDocumentStore(repository);
          final note = await documents.importDocument(
            title: 'Office',
            fileName: starter.fileName,
            bytes: starter.bytes,
          );
          final originalKey = await cache.coverKey(repository, note);
          final source = await documents.readLatest(note);
          final variant = await documents.commitDerivedPdf(
            await documents.beginEdit(note),
            pdfBytes: red,
            pageCount: 1,
          );
          final variantKey = await cache.coverKey(repository, note);
          expect(variantKey, isNot(originalKey));
          expect(variantKey, contains(variant.revision.revisionId));
          expect(variantKey, isNot(contains(source.revision.revisionId)));
          final beforeCover = (await cache.getOrCreate(repository, note))!;
          expect(
            await contentPixels(beforeCover, redOnly: true),
            greaterThan(1000),
          );
          expect(await contentPixels(beforeCover, blueOnly: true), 0);
          expect(engine.calls, 0);

          final core = EditorCoreInfo(filePath: '/office-derived-cover-test')
            ..backgroundColor = Colors.white
            ..backgroundPattern = .none;
          final page = EditorPage(size: const Size(1000, 1400));
          core.pages.add(page);
          page.backgroundImage = PdfEditorImage(
            id: 0,
            assetCache: core.assetCache,
            pdfBytes: red,
            pdfFile: null,
            pdfPage: 0,
            pageIndex: 0,
            pageSize: page.size,
            naturalSize: const Size(200, 300),
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          );
          page.strokes.add(
            Stroke(
              color: Colors.blue,
              pressureEnabled: false,
              options: StrokeOptions(size: 50, thinning: 0),
              pageIndex: 0,
              page: page,
              toolId: ToolId.ballpointPen,
            )..addPoints(const [Offset(100, 100), Offset(900, 100)]),
          );
          try {
            final annotations = await OfficeAnnotationStore(repository)
                .open(note, source, preview: variant);
            await annotations.saveSnapshot(core, 0);
            final ink = (await repository.heads(variant.bindingId)).single;
            final annotatedKey = await cache.coverKey(repository, note);
            expect(annotatedKey, '$variantKey-${ink.revisionId}');
            final afterCover = (await cache.getOrCreate(repository, note))!;
            expect(
              await contentPixels(afterCover, redOnly: true),
              greaterThan(1000),
            );
            expect(
              await contentPixels(afterCover, blueOnly: true),
              greaterThan(100),
            );

            await documents.commitDerivedPdf(
              await documents.beginEdit(note),
              pdfBytes: green,
              pageCount: 1,
            );
            expect(await cache.coverKey(repository, note), isNull);
            expect(await cache.getOrCreate(repository, note), isNull);
            expect(engine.calls, 0);
            expect(
              (await repository.heads(note.sourceEntityId!)).single.revisionId,
              source.revision.revisionId,
            );
          } finally {
            core.dispose();
          }
        } finally {
          Pdfrx.pdfiumModulePath = previous;
        }
      });
    },
    skip:
        !Platform.isWindows ||
        !File('build/windows/x64/runner/Release/pdfium.dll').existsSync(),
  );

  test('ambiguous Markdown heads and malformed typed payloads have a safe fallback', () async {
    final note = await store.create(
      'Conflict',
      documentKind: VaultDocumentKind.markdown,
    );
    await repository.commit(
      entityId: note.markdownEntityId,
      kind: EntityKind.markdown,
      ownerNoteId: note.id,
      files: {'summary.md': Uint8List.fromList(utf8.encode('branch'))},
      parentRevisionIds: [],
    );
    expect(await cache.coverKey(repository, note), isNull);
    expect(await cache.getOrCreate(repository, note), isNull);
    final invalid = await store.create(
      'Invalid',
      documentKind: VaultDocumentKind.page,
    );
    await body(invalid, 'page.json', {
      'version': 1,
      'blocks': [
        {'id': newId(), 'type': 4},
      ],
    });
    expect(await cache.getOrCreate(repository, invalid), isNull);
  });

  testWidgets(
    'lazy grid and list request cards beyond 48 only as they are built and request again after navigation',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final notes = (await tester.runAsync(
        () async => [
          for (var i = 0; i < 75; i++)
            await store.create(
              'Document ${i.toString().padLeft(3, '0')}',
              documentKind: VaultDocumentKind.markdown,
            ),
        ],
      ))!;
      final requested = <String>{};
      Widget library() => MaterialApp(
        home: Scaffold(
          body: LibraryHome(
            notes: notes,
            folders: const [],
            currentFolderId: null,
            onOpenNote: (_) {},
            onOpenFolder: (_) {},
            onCreate: (_) {},
            onPreviewRequested: (note) => requested.add(note.id),
          ),
        ),
      );
      await tester.pumpWidget(library());
      await tester.pump();
      expect(requested, isNotEmpty);
      expect(requested.length, lessThan(48));
      await tester.dragUntilVisible(
        find.byKey(ValueKey('library-note-${notes[60].revision.revisionId}')),
        find.byType(CustomScrollView),
        const Offset(0, -650),
        maxIteration: 40,
      );
      await tester.pump();
      expect(requested, contains(notes[60].id));
      await tester.pumpWidget(const SizedBox());
      requested.clear();
      await tester.pumpWidget(library());
      await tester.pump();
      expect(requested, isNotEmpty);
      requested.clear();
      await tester.tap(find.byKey(const ValueKey('library-layout-toggle')));
      await tester.pumpAndSettle();
      expect(requested.length, lessThan(48));
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
