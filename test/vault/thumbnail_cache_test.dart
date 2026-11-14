import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
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
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

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
    temp = await Directory.systemTemp.createTemp('ink-thumbnails-');
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    store = WorkspaceStore(repository);
    cache = ThumbnailCache(Directory('${temp.path}/previews'));
    await FileManager.init(shouldWatchRootDirectory: false);
  });
  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  EditorCoreInfo core({Color? ink}) {
    final core = EditorCoreInfo(filePath: '/thumbnail-test')
      ..backgroundColor = Colors.white
      ..backgroundPattern = .none;
    final page = EditorPage(size: const Size(1000, 1400));
    core.pages.add(page);
    if (ink != null) {
      page.strokes.add(
        Stroke(
          color: ink,
          pressureEnabled: false,
          options: StrokeOptions(size: 40, thinning: 0),
          pageIndex: 0,
          page: page,
          toolId: ToolId.ballpointPen,
        )..addPoints(const [Offset(100, 100), Offset(900, 100)]),
      );
    }
    return core;
  }

  Future<RevisionRecord> commit(
    VaultNote note,
    EditorCoreInfo core, {
    List<String>? parents,
  }) async => repository.commit(
    entityId: note.inkEntityId,
    kind: EntityKind.ink,
    ownerNoteId: note.id,
    files: await SaberInkAdapter.capture(core, 0),
    parentRevisionIds: parents ?? [],
  );

  Future<(int, int, int)> inspectPng(File file) async {
    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    try {
      final image = (await codec.getNextFrame()).image;
      try {
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        var red = 0;
        for (var i = 0; i < pixels.length; i += 4) {
          if (pixels[i] > 150 &&
              pixels[i + 1] < 100 &&
              pixels[i + 2] < 100 &&
              pixels[i + 3] > 100)
            red++;
        }
        return (image.width, image.height, red);
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  test('MCP page rendering includes real ink at readable resolution without changing the snapshot', () async {
    final note = await store.create('Readable page');
    final drawing = core(ink: Colors.red);
    final revision = await commit(note, drawing);
    drawing.dispose();
    final before = await repository.readFiles(revision);
    await cache.retire();
    final rendered = await cache.renderSnapshotPage(repository, revision);
    final file = await File('${temp.path}/readable.png')
        .writeAsBytes(rendered.png);
    final (width, height, red) = await inspectPng(file);
    expect(width, 1200);
    expect(height, 1680);
    expect(red, greaterThan(1000));
    expect(rendered.pageCount, greaterThanOrEqualTo(1));
    expect(
      (await repository.readFiles(revision))['main.sbn2'],
      before['main.sbn2'],
    );
    await expectLater(
      cache.renderSnapshotPage(repository, revision, pageIndex: -1),
      throwsRangeError,
    );
  });

  for (final failWrite in [false, true]) {
    testWidgets(
      'retirement waits for an admitted PNG ${failWrite ? 'failure cleanup' : 'rename'}',
      (tester) async {
        await tester.runAsync(() async {
          final writing = Completer<File>();
          final release = Completer<void>();
          var writes = 0;
          cache = ThumbnailCache(
            cache.root,
            writePng: (temporary, bytes) async {
              writes++;
              final output = await temporary.open(mode: FileMode.write);
              try {
                await output.writeFrom(bytes);
                await output.flush();
                writing.complete(temporary);
                await release.future;
              } finally {
                await output.close();
              }
              if (failWrite)
                throw const FileSystemException('Test PNG write failure');
            },
          );
          final note = await store.create('Publishing cover');
          final drawing = core(ink: Colors.red);
          final revision = await commit(note, drawing);
          final pending = cache.getOrCreate(repository, note);
          Future<void>? retirement;
          File? cover;
          List<String>? filesAtRetirement;
          late File temporary;
          try {
            temporary = await writing.future.timeout(
              const Duration(seconds: 8),
            );
            var retired = false;
            retirement = cache.retire().then<void>((_) {
              retired = true;
              filesAtRetirement = temporary.parent
                  .listSync()
                  .whereType<File>()
                  .map((file) => file.path)
                  .toList();
            });
            await Future<void>.delayed(Duration.zero);
            expect(temporary.existsSync(), isTrue);
            expect(retired, isFalse);
            expect(await cache.coverKey(repository, note), isNull);
            expect(await cache.getOrCreate(repository, note), isNull);
            expect(
              await cache.capture(repository, note, revision, drawing),
              isNull,
            );
            expect(writes, 1);
          } finally {
            release.complete();
            cover = await pending;
            await retirement;
            drawing.dispose();
          }
          expect(temporary.existsSync(), isFalse);
          expect(cover, isNull);
          final files = await cache.root
              .list(recursive: true)
              .where((entry) => entry is File)
              .toList();
          if (failWrite) {
            expect(filesAtRetirement, isEmpty);
            expect(files, isEmpty);
          } else {
            expect(files.single.path, endsWith('.png'));
            expect(filesAtRetirement, hasLength(1));
            expect(
              FileSystemEntity.identicalSync(
                filesAtRetirement!.single,
                files.single.path,
              ),
              isTrue,
            );
            expect(
              (await inspectPng(files.single as File)).$3,
              greaterThan(100),
            );
          }
          expect(await cache.getOrCreate(repository, note), isNull);
        });
      },
    );
  }

  testWidgets('retirement skips a late Office result and a queued cover', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final engine = _BlockingOfficeCoverPreview();
      final result = _ObservedOfficeCoverPreview();
      var writes = 0;
      cache = ThumbnailCache(
        cache.root,
        officePreviewEngine: engine,
        writePng: (temporary, bytes) async {
          writes++;
          await temporary.writeAsBytes(bytes, flush: true);
        },
      );
      final office = await OfficeDocumentStore(repository).importDocument(
        title: 'Active conversion',
        fileName: 'source.docx',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final markdown = await store.createMarkdown(
        'Queued cover',
        Uint8List.fromList('# This cover can render'.codeUnits),
      );
      final active = cache.getOrCreate(repository, office);
      Future<File?>? queued;
      late File copiedSource;
      File? activeCover;
      File? queuedCover;
      try {
        copiedSource = await engine.entered.future.timeout(
          const Duration(seconds: 8),
        );
        expect(copiedSource.existsSync(), isTrue);
        queued = cache.getOrCreate(repository, markdown);
        await repository.revisions();
        await cache.retire().timeout(const Duration(seconds: 3));
        expect(copiedSource.existsSync(), isTrue);
        expect(
          await cache
              .getOrCreate(repository, markdown)
              .timeout(const Duration(seconds: 3)),
          isNull,
        );
        expect(await cache.coverKey(repository, markdown), isNull);
      } finally {
        engine.finish.complete(result);
        activeCover = await active;
        queuedCover = await queued;
      }
      expect(activeCover, isNull);
      expect(queuedCover, isNull);
      expect(result.pathReads, 0);
      expect(result.disposals, 1);
      expect(copiedSource.existsSync(), isFalse);
      expect(writes, 0);
      expect(await cache.root.list(recursive: true).toList(), isEmpty);
    });
  });

  testWidgets(
    'thumbnail rasterizes actual first-page ink and leaves canonical content unchanged',
    (tester) async {
      await tester.runAsync(() async {
        final note = await store.create('Ink');
        final source = core(ink: Colors.red);
        final revision = await commit(note, source);
        final before = await repository.readFiles(revision);
        final revisionCount = (await repository.revisions()).length;
        final thumbnail = await cache.getOrCreate(repository, note);
        expect(thumbnail, isNotNull);
        final pixels = await inspectPng(thumbnail!);
        expect(pixels.$1, 240);
        expect(pixels.$2, lessThanOrEqualTo(320));
        expect(pixels.$3, greaterThan(100));
        expect(await repository.readFiles(revision), before);
        expect((await repository.revisions()).length, revisionCount);
        source.dispose();
        final blankNote = await store.create('Blank');
        final blank = core();
        await commit(blankNote, blank);
        final blankThumbnail = await cache.getOrCreate(repository, blankNote);
        expect((await inspectPng(blankThumbnail!)).$3, 0);
        blank.dispose();
      });
    },
  );

  testWidgets(
    'same head reuses cache and a later ink head gets a different file',
    (tester) async {
      await tester.runAsync(() async {
        final note = await store.create('Versioned');
        final firstCore = core(ink: Colors.red);
        final first = await commit(note, firstCore);
        final file = (await cache.getOrCreate(repository, note))!;
        final oldTime = DateTime(2000);
        await file.setLastModified(oldTime);
        expect((await cache.getOrCreate(repository, note))!.path, file.path);
        expect((file.lastModifiedSync()).year, 2000);
        final secondCore = core(ink: Colors.blue);
        await commit(note, secondCore, parents: [first.revisionId]);
        final next = (await cache.getOrCreate(repository, note))!;
        expect(next.path, isNot(file.path));
        expect((await inspectPng(next)).$3, 0);
        expect(file.existsSync(), isTrue);
        firstCore.dispose();
        secondCore.dispose();
      });
    },
  );

  testWidgets(
    'image document regenerates a cover from the actual saved PNG background',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
            .drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
        final picture = recorder.endRecording();
        late Uint8List png;
        try {
          final image = await picture.toImage(64, 64);
          try {
            final encoded = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            png = encoded.buffer.asUint8List(
              encoded.offsetInBytes,
              encoded.lengthInBytes,
            );
          } finally {
            image.dispose();
          }
        } finally {
          picture.dispose();
        }
        final note = await store.create(
          'Image page',
          documentKind: VaultDocumentKind.image,
        );
        final source = core();
        source.pages.first.backgroundImage = PngEditorImage(
          id: 0,
          assetCache: source.assetCache,
          extension: '.png',
          imageProvider: MemoryImage(png),
          pageIndex: 0,
          pageSize: const Size(1000, 1400),
          naturalSize: const Size(64, 64),
          srcRect: const Rect.fromLTWH(0, 0, 64, 64),
          dstRect: const Rect.fromLTWH(0, 0, 1000, 1400),
          onMoveImage: null,
          onDeleteImage: null,
          onMiscChange: null,
        );
        final revision = await commit(note, source);
        final originalAsset = (await repository.readFiles(
          revision,
        ))['main.sbn2.0'];
        final thumbnail = await cache.getOrCreate(repository, note);
        expect(thumbnail, isNotNull);
        expect((await inspectPng(thumbnail!)).$3, greaterThan(1000));
        expect(
          (await repository.readFiles(revision))['main.sbn2.0'],
          originalAsset,
        );
        source.dispose();
      });
    },
  );

  testWidgets(
    'native PDF background is rasterized before its thumbnail is committed',
    (tester) async {
      await tester.runAsync(() async {
        final previousModulePath = Pdfrx.pdfiumModulePath;
        Pdfrx.pdfiumModulePath = File(
          'build/windows/x64/runner/Release/pdfium.dll',
        ).absolute.path;
        try {
          await pdfrxInitialize(tmpPath: temp.path);
          final pdf = pw.Document();
          pdf.addPage(
            pw.Page(
              pageFormat: const PdfPageFormat(200, 300),
              margin: pw.EdgeInsets.zero,
              build: (_) =>
                  pw.Container(width: 200, height: 300, color: PdfColors.red),
            ),
          );
          final bytes = await pdf.save();
          final note = await store.create(
            'PDF page',
            documentKind: VaultDocumentKind.pdf,
          );
          final source = core();
          source.pages.first.backgroundImage = PdfEditorImage(
            id: 0,
            assetCache: source.assetCache,
            pdfBytes: bytes,
            pdfFile: null,
            pdfPage: 0,
            pageIndex: 0,
            pageSize: const Size(1000, 1400),
            naturalSize: const Size(200, 300),
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          );
          final revision = await commit(note, source);
          final canonical = await repository.readFiles(revision);
          final thumbnail = await cache.getOrCreate(repository, note);
          expect(thumbnail, isNotNull);
          expect((await inspectPng(thumbnail!)).$3, greaterThan(1000));
          expect(await repository.readFiles(revision), canonical);
          source.dispose();
        } finally {
          Pdfrx.pdfiumModulePath = previousModulePath;
        }
      });
    },
    skip:
        !Platform.isWindows ||
        !File('build/windows/x64/runner/Release/pdfium.dll').existsSync(),
  );

  for (final validPdf in [true, false]) {
    testWidgets(
      'Office cover releases its actual preview lease once after ${validPdf ? 'successful rendering' : 'PDF rendering fails'}',
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
                  build: (_) => pw.Container(
                    width: 200,
                    height: 300,
                    color: PdfColors.red,
                  ),
                ),
              );
            final bytes = validPdf
                ? await pdf.save()
                : Uint8List.fromList(
                    '%PDF-1.7\ninvalid page tree\n%%EOF\n'.codeUnits,
                  );
            final note = await OfficeDocumentStore(repository).importDocument(
              title: 'Owned Office cover',
              fileName: 'saved.docx',
              bytes: Uint8List.fromList([1, 2, 3]),
            );
            final revision = (await repository.heads(note.sourceEntityId!))
                .single;
            final canonical = await repository.readFiles(revision);
            final revisionCount = (await repository.revisions()).length;
            final owned = await Directory('${temp.path}/native-owned-output')
                .create();
            final unrelated = await File('${temp.path}/unrelated.docx')
                .writeAsString('retained');
            var releases = 0;
            File? copiedSource;
            final backend = _OfficeCoverInspection((sourcePath, preview) async {
              expect(preview, isTrue);
              copiedSource = File(sourcePath);
              final output = await File('${owned.path}/preview.pdf')
                  .writeAsBytes(bytes);
              return WindowsOfficeSnapshot.fromJson(
                {
                  'kind': 'word',
                  'sourceSha256': sha256
                      .convert(await copiedSource!.readAsBytes())
                      .toString(),
                  'paragraphs': [],
                  'tables': [],
                  'slides': [],
                  'previewPdfPath': output.path,
                  'previewPageCount': 1,
                },
                onDisposePreview: () async {
                  releases++;
                  expect(
                    copiedSource!.existsSync(),
                    isTrue,
                    reason:
                        'Release the backend before removing its caller input',
                  );
                  await owned.delete(recursive: true);
                },
              );
            });
            cache = ThumbnailCache(
              Directory('${temp.path}/office-cover-lease'),
              officePreviewEngine: OfficePreviewEngine(
                isWindows: true,
                isAndroid: false,
                windowsEngine: backend,
              ),
            );
            final cover = await cache.getOrCreate(repository, note);
            if (validPdf) {
              expect(cover, isNotNull);
              expect((await inspectPng(cover!)).$3, greaterThan(1000));
              expect(
                (await cache.getOrCreate(repository, note))!.path,
                cover.path,
              );
              expect(backend.calls, 1);
            } else {
              expect(cover, isNull);
            }
            expect(releases, 1);
            expect(owned.existsSync(), isFalse);
            expect(copiedSource!.existsSync(), isFalse);
            expect(await unrelated.readAsString(), 'retained');
            expect(await repository.readFiles(revision), canonical);
            expect((await repository.revisions()).length, revisionCount);
          } finally {
            Pdfrx.pdfiumModulePath = previous;
          }
        });
      },
      skip:
          !Platform.isWindows ||
          !File('build/windows/x64/runner/Release/pdfium.dll').existsSync(),
    );
  }

  test(
    'Office cover never infers output ownership from a legacy result path',
    () async {
      final note = await OfficeDocumentStore(repository).importDocument(
        title: 'Legacy preview',
        fileName: 'saved.docx',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final external = await Directory(
        '${temp.path}/personal-ink-vault-office-unowned',
      ).create();
      final output = await File('${external.path}/preview.pdf')
          .writeAsString('malformed');
      final unrelated = await File('${external.path}/unrelated.docx')
          .writeAsString('retained');
      cache = ThumbnailCache(
        Directory('${temp.path}/legacy-office-cover'),
        officePreviewEngine: _LegacyOfficeCoverPreview(output.path),
      );
      expect(await cache.getOrCreate(repository, note), isNull);
      expect(await output.readAsString(), 'malformed');
      expect(await unrelated.readAsString(), 'retained');
      expect(external.existsSync(), isTrue);
      expect(
        await cache.root
            .list(recursive: true)
            .where((entry) => entry.path.endsWith('.docx'))
            .toList(),
        isEmpty,
      );
    },
  );

  test('missing or malformed snapshot and unsafe assets return fallback without changing source', () async {
    final note = await store.create('Malformed');
    final noBody = await repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: {
        'unexpected': Uint8List.fromList([1, 2]),
      },
      parentRevisionIds: [],
    );
    expect(await cache.getOrCreate(repository, note), isNull);
    final malformed = await repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: {
        'main.sbn2': Uint8List.fromList([1, 2, 3]),
        'main.sbn2.unsafe': Uint8List(1),
      },
      parentRevisionIds: [noBody.revisionId],
    );
    final before = await repository.readFiles(malformed);
    expect(await cache.getOrCreate(repository, note), isNull);
    expect(await repository.readFiles(malformed), before);
  });

  testWidgets(
    'corrupt local PNG regenerates instead of being exposed as a valid cover',
    (tester) async {
      await tester.runAsync(() async {
        final note = await store.create('Recover cache');
        final source = core(ink: Colors.red);
        await commit(note, source);
        final file = (await cache.getOrCreate(repository, note))!;
        await file.writeAsBytes(
          Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
        );
        final regenerated = await cache.getOrCreate(repository, note);
        expect((await inspectPng(regenerated!)).$3, greaterThan(100));
        expect(
          (await cache.root
              .list(recursive: true)
              .where((entry) => entry.path.endsWith('.tmp'))
              .toList()),
          isEmpty,
        );
        source.dispose();
      });
    },
  );

  test('unsupported document types and ambiguous ink heads have no fabricated thumbnail', () async {
    for (final kind in [
      VaultDocumentKind.markdown,
      VaultDocumentKind.office,
      VaultDocumentKind.infinite,
    ]) {
      expect(
        await cache.getOrCreate(
          repository,
          await store.create(kind.name, documentKind: kind),
        ),
        isNull,
      );
    }
    final note = await store.create('Conflict');
    for (var i = 0; i < 2; i++) {
      await repository.commit(
        entityId: note.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: note.id,
        files: {
          'main.sbn2': Uint8List.fromList([i]),
        },
        parentRevisionIds: [],
      );
    }
    expect(await cache.getOrCreate(repository, note), isNull);
  });
}

class _OfficeCoverInspection extends WindowsOfficeEngine {
  new(this.inspectSource);
  final Future<WindowsOfficeSnapshot> Function(String, bool) inspectSource;
  var calls = 0;
  @override
  Future<bool> get available async => true;
  @override
  Future<WindowsOfficeSnapshot> inspect(
    String sourcePath, {
    bool preview = false,
  }) {
    calls++;
    return inspectSource(sourcePath, preview);
  }
}

class _LegacyOfficeCoverPreview extends OfficePreviewEngine {
  new(this.outputPath) : super(isWindows: true, isAndroid: false);
  final String outputPath;
  @override
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) async => OfficePreviewResult(
    pdfPath: outputPath,
    pdfSha256: 'legacy',
    pageCount: 1,
    sourceSha256: 'legacy',
    engineVersion: 'legacy',
  );
}

class _BlockingOfficeCoverPreview extends OfficePreviewEngine {
  new() : super(isWindows: true, isAndroid: false);

  final entered = Completer<File>();
  final finish = Completer<OfficePreviewResult>();

  @override
  Future<OfficePreviewResult> preview({
    required String sourcePath,
    required String sessionId,
  }) {
    entered.complete(File(sourcePath));
    return finish.future;
  }
}

class _ObservedOfficeCoverPreview extends OfficePreviewResult {
  new()
    : super(
        pdfPath: 'unexpected-preview.pdf',
        pdfSha256: 'test',
        pageCount: 1,
        sourceSha256: 'test',
        engineVersion: 'test',
      );

  var pathReads = 0;
  var disposals = 0;

  @override
  String get pdfPath {
    pathReads++;
    return super.pdfPath;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}
