import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
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
import 'package:saber/data/vault/pdf_import_state.dart';
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

  testWidgets('retirement waits for an admitted cover facts write', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final writing = Completer<File>();
      final release = Completer<void>();
      cache = ThumbnailCache(
        cache.root,
        writeFacts: (temporary, json) async {
          await temporary.writeAsString(json, flush: true);
          writing.complete(temporary);
          await release.future;
        },
      );
      final note = await store.create('Facts publishing');
      final drawing = core(ink: Colors.red);
      await commit(note, drawing);
      drawing.dispose();
      final pending = cache.getOrCreate(repository, note);
      final temporary = await writing.future.timeout(
        const Duration(seconds: 8),
      );
      var retired = false;
      final retirement = cache.retire().then<void>((_) => retired = true);
      await Future<void>.delayed(Duration.zero);
      expect(temporary.existsSync(), isTrue);
      expect(retired, isFalse);
      release.complete();
      await retirement;
      final cover = await pending;
      expect(cover, isNull);
      final names = (await cache.root
              .list(recursive: true)
              .where((entry) => entry is File)
              .toList())
          .map((entry) => entry.path)
          .toList();
      expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
      expect(names.where((n) => n.endsWith('.png')), hasLength(1));
      expect(names.where((n) => n.endsWith('.facts.json')), hasLength(1));
    });
  });

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

  testWidgets(
    'imported PDF note saved with its import marker still gets a cover',
    (tester) async {
      await tester.runAsync(() async {
        final previousModulePath = Pdfrx.pdfiumModulePath;
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
          final note = await store.create(
            'Imported PDF',
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
          // WorkspaceController.saveInk adds this marker to every save of an imported PDF note.
          final files = await SaberInkAdapter.capture(source, 0);
          files[PdfImportMarker.fileName] = PdfImportMarker(
            vaultId: repository.vaultId,
            noteId: note.id,
            sourceEntityId: newId(),
            sourceRevisionId: newId(),
            sourceSha256: sha256.convert(bytes).toString(),
          ).encode();
          final revision = await repository.commit(
            entityId: note.inkEntityId,
            kind: EntityKind.ink,
            ownerNoteId: note.id,
            files: files,
            parentRevisionIds: [],
          );
          expect(revision.blobs.keys, contains(PdfImportMarker.fileName));
          final thumbnail = await cache.getOrCreate(repository, note);
          expect(thumbnail, isNotNull);
          expect((await inspectPng(thumbnail!)).$3, greaterThan(1000));
          final page = await cache.renderSnapshotPage(
            repository,
            revision,
            width: 400,
          );
          expect(page.pageIndex, 0);
          expect(page.png, isNotEmpty);
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

  test('a handwriting cover records its page count and first-page aspect', () async {
    final note = await store.create('Three pages');
    final drawing = core(ink: Colors.red);
    drawing.pages.add(EditorPage(size: const Size(1000, 1400)));
    drawing.pages.add(EditorPage(size: const Size(1000, 1400)));
    await commit(note, drawing);
    drawing.dispose();
    final thumbnail = await cache.getOrCreate(repository, note);
    expect(thumbnail, isNotNull);
    final facts = await ThumbnailCache.readCoverFacts(thumbnail!);
    expect(facts, isNotNull);
    expect(facts!.pages, 3);
    expect(facts.aspect, closeTo(1000 / 1400, 0.001));
  });

  test('a cover written without facts reads as unknown', () async {
    final png = File('${temp.path}/plain.png')..writeAsBytesSync([1, 2, 3]);
    expect(await ThumbnailCache.readCoverFacts(png), isNull);
    File('${png.path}.facts.json').writeAsStringSync('not json');
    expect(await ThumbnailCache.readCoverFacts(png), isNull);
  });

  testWidgets(
    'a pdf note without ink gets its first pdf page as cover',
    (tester) async {
      await tester.runAsync(() async {
        final previousModulePath = Pdfrx.pdfiumModulePath;
        Pdfrx.pdfiumModulePath = File(
          'build/windows/x64/runner/Release/pdfium.dll',
        ).absolute.path;
        try {
          await pdfrxInitialize(tmpPath: temp.path);
          final pdf = pw.Document();
          for (var i = 0; i < 2; i++) {
            pdf.addPage(
              pw.Page(
                pageFormat: const PdfPageFormat(400, 200),
                margin: pw.EdgeInsets.zero,
                build: (_) =>
                    pw.Container(width: 400, height: 200, color: PdfColors.red),
              ),
            );
          }
          final note = await store.createWithSource(
            'Source only',
            fileName: 'source.pdf',
            bytes: await pdf.save(),
            documentKind: VaultDocumentKind.pdf,
          );
          final thumbnail = await cache.getOrCreate(repository, note);
          expect(thumbnail, isNotNull);
          expect((await inspectPng(thumbnail!)).$3, greaterThan(1000));
          final facts = await ThumbnailCache.readCoverFacts(thumbnail);
          expect(facts, isNotNull);
          expect(facts!.pages, 2);
          expect(facts.aspect, greaterThan(1));
        } finally {
          Pdfrx.pdfiumModulePath = previousModulePath;
        }
      });
    },
    skip:
        !Platform.isWindows ||
        !File('build/windows/x64/runner/Release/pdfium.dll').existsSync(),
  );

  test('a cover snapshot still refuses files other than the body, its assets and the PDF marker', () async {
    final note = await store.create(
      'Extra file',
      documentKind: VaultDocumentKind.pdf,
    );
    final drawing = core(ink: Colors.red);
    final files = await SaberInkAdapter.capture(drawing, 0);
    drawing.dispose();
    files['notes.json'] = Uint8List.fromList('{}'.codeUnits);
    final revision = await repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: files,
      parentRevisionIds: [],
    );
    expect(await cache.getOrCreate(repository, note), isNull);
    await expectLater(
      cache.renderSnapshotPage(repository, revision),
      throwsFormatException,
    );
  });

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

  /// An Office·한글 original as a ZIP of [parts]; the [stored] ones are kept
  /// uncompressed, as PowerPoint keeps its thumbnail.
  Uint8List officeZip(
    Map<String, List<int>> parts, {
    Set<String> stored = const {},
  }) {
    final archive = Archive();
    for (final MapEntry(key: name, value: bytes) in parts.entries) {
      archive.addFile(
        stored.contains(name)
            ? ArchiveFile.noCompress(name, bytes.length, bytes)
            : ArchiveFile(name, bytes.length, bytes),
      );
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  List<int> redPicture(int width, int height, {bool png = false}) {
    final picture = img.Image(width: width, height: height);
    img.fill(picture, color: img.ColorRgb8(230, 20, 20));
    return png ? img.encodePng(picture) : img.encodeJpg(picture);
  }

  List<int> thumbnailRels(String target) => utf8.encode(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>'
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail" Target="$target"/>'
    '</Relationships>',
  );

  Future<VaultNote> office(String fileName, Uint8List bytes) =>
      OfficeDocumentStore(repository)
          .importDocument(title: fileName, fileName: fileName, bytes: bytes);

  test('an office original with an embedded preview gets that picture as its cover when no engine can convert', () async {
    final engine = _NoBackgroundOfficePreview();
    cache = ThumbnailCache(
      Directory('${temp.path}/picture-covers'),
      officePreviewEngine: engine,
    );
    // The relationship names the picture, whatever it is called.
    final note = await office(
      'slides.pptx',
      officeZip(
        {
          '[Content_Types].xml': utf8.encode('<Types/>'),
          '_rels/.rels': thumbnailRels('/docProps/first-slide.jpeg'),
          'ppt/presentation.xml': utf8.encode('<presentation/>'),
          'docProps/first-slide.jpeg': redPicture(256, 144),
        },
        stored: {'docProps/first-slide.jpeg'},
      ),
    );
    final cover = await cache.getOrCreate(repository, note);
    expect(cover, isNotNull);
    final (width, height, red) = await inspectPng(cover!);
    expect(width, 240);
    expect(height, 135);
    expect(red, greaterThan(240 * 135 * 9 ~/ 10));
    final facts = await ThumbnailCache.readCoverFacts(cover);
    expect(facts!.aspect, closeTo(256 / 144, 1e-9));
    expect(facts.pages, isNull);
    expect(engine.calls, 0);
    // Kept like any other cover.
    expect((await cache.getOrCreate(repository, note))!.path, cover.path);

    // A picture larger than the cover is drawn at the cover's size, and the
    // facts keep the picture's own shape.
    final large = await office(
      'large.pptx',
      officeZip({'docProps/thumbnail.jpeg': redPicture(1600, 900)}),
    );
    final largeCover = await cache.getOrCreate(repository, large);
    final (largeWidth, largeHeight, largeRed) = await inspectPng(largeCover!);
    expect((largeWidth, largeHeight), (240, 135));
    expect(largeRed, greaterThan(240 * 135 * 9 ~/ 10));
    expect(
      (await ThumbnailCache.readCoverFacts(largeCover))!.aspect,
      closeTo(1600 / 900, 1e-9),
    );
  });

  /// [zip] with its entry [name] marked as a Unix symbolic link, as a ZIP
  /// made on Linux or macOS stores one: host 3 in "version made by" and file
  /// type 0xA000 in the external attributes of its central directory record.
  Uint8List asSymlink(Uint8List zip, String name) {
    final data = ByteData.sublistView(zip);
    for (var at = 0; at + 46 <= zip.length; at++) {
      if (data.getUint32(at, Endian.little) != 0x02014b50) continue;
      final length = data.getUint16(at + 28, Endian.little);
      if (utf8.decode(zip.sublist(at + 46, at + 46 + length)) != name) {
        continue;
      }
      zip[at + 5] = 3;
      data.setUint32(at + 38, 0xA1FF << 16, Endian.little);
    }
    return zip;
  }

  test(
    'a symbolic link entry is never read while the preview picture is found',
    () async {
      final engine = _NoBackgroundOfficePreview();
      cache = ThumbnailCache(
        Directory('${temp.path}/link-covers'),
        officePreviewEngine: engine,
      );
      // 1 MiB that is no text. Decoding the whole package inflates every
      // link entry and fails on this one; reading the directory touches none.
      final note = await office(
        'linked.odp',
        asSymlink(
          officeZip({
            'link': Uint8List(1 << 20)..fillRange(0, 1 << 20, 0xff),
            'Thumbnails/thumbnail.png': redPicture(70, 100, png: true),
          }),
          'link',
        ),
      );
      final cover = await cache.getOrCreate(repository, note);
      expect(cover, isNotNull);
      expect((await inspectPng(cover!)).$3, greaterThan(1000));
    },
  );

  testWidgets(
    'an office original with both a kept PDF and an embedded preview gets its cover from the PDF',
    (tester) async {
      await tester.runAsync(() async {
        final previous = Pdfrx.pdfiumModulePath;
        Pdfrx.pdfiumModulePath = File(
          'build/windows/x64/runner/Release/pdfium.dll',
        ).absolute.path;
        try {
          await pdfrxInitialize(tmpPath: temp.path);
          final engine = _NoBackgroundOfficePreview();
          cache = ThumbnailCache(
            Directory('${temp.path}/pdf-before-picture'),
            officePreviewEngine: engine,
          );
          final note = await office(
            'both.pptx',
            officeZip({
              '_rels/.rels': thumbnailRels('docProps/thumbnail.jpeg'),
              'docProps/thumbnail.jpeg': redPicture(256, 144),
            }),
          );
          final pdf = pw.Document()
            ..addPage(
              pw.Page(
                pageFormat: const PdfPageFormat(200, 300),
                margin: pw.EdgeInsets.zero,
                build: (_) => pw.Container(
                  width: 200,
                  height: 300,
                  color: PdfColors.blue,
                ),
              ),
            );
          expect(
            await OfficeDocumentStore(repository)
                .keepFirstPdf(note, pdfBytes: await pdf.save(), pageCount: 1),
            isTrue,
          );
          final cover = await cache.getOrCreate(repository, note);
          expect(cover, isNotNull);
          // The PDF's blue page with its page count and shape, not the red
          // 16:9 picture.
          expect((await inspectPng(cover!)).$3, 0);
          final facts = await ThumbnailCache.readCoverFacts(cover);
          expect(facts!.pages, 1);
          expect(facts.aspect, closeTo(200 / 300, 1e-6));
          expect(engine.calls, 0);
        } finally {
          Pdfrx.pdfiumModulePath = previous;
        }
      });
    },
    skip:
        !Platform.isWindows ||
        !File('build/windows/x64/runner/Release/pdfium.dll').existsSync(),
  );

  test('a broken preview picture gives no cover and no error', () async {
    final engine = _NoBackgroundOfficePreview();
    cache = ThumbnailCache(
      Directory('${temp.path}/broken-picture-covers'),
      officePreviewEngine: engine,
    );
    final logged = <String>[];
    final listening = Logger.root.onRecord.listen((record) {
      if (record.loggerName == 'PIVCover') logged.add(record.message);
    });
    addTearDown(listening.cancel);
    final png = redPicture(40, 30, png: true);
    final notes = <String, VaultNote>{};
    for (final (fileName, bytes) in [
      // A PNG whose header names no real colour type: its size passes the
      // check before decoding, the picture itself does not decode.
      (
        'undecodable.odp',
        officeZip({
          'Thumbnails/thumbnail.png': Uint8List.fromList(png)..[25] = 7,
        }),
      ),
      // A Windows metafile is not drawn.
      (
        'vector.docx',
        officeZip({
          '_rels/.rels': thumbnailRels('docProps/thumbnail.wmf'),
          'docProps/thumbnail.wmf': [0xd7, 0xcd, 0xc6, 0x9a, 0, 0, 0, 0],
        }),
      ),
      // Larger than 8 MiB.
      (
        'huge.odt',
        officeZip({
          'Thumbnails/thumbnail.png': Uint8List((8 << 20) + 1)..setAll(0, png),
        }),
      ),
      ('not-a-zip.pptx', Uint8List.fromList([1, 2, 3])),
    ]) {
      final note = notes[fileName] = await office(fileName, bytes);
      expect(
        await cache.getOrCreate(repository, note),
        isNull,
        reason: fileName,
      );
    }
    expect(engine.calls, 0);
    // Nothing was written for them.
    expect(cache.root.existsSync(), isFalse);
    // A package that cannot be read says why in the log, like other covers.
    expect(
      logged,
      contains(
        allOf(
          contains(notes['not-a-zip.pptx']!.id),
          contains('preview picture not read'),
        ),
      ),
    );
  });

  for (final (fileName, part) in [
    ('notes.odt', 'Thumbnails/thumbnail.png'),
    ('slides.odp', 'Thumbnails/thumbnail.png'),
    ('letter.hwpx', 'Preview/PrvImage.png'),
    ('report.docx', 'docProps/thumbnail.png'),
  ]) {
    test('the preview picture of $fileName is read from $part', () async {
      final engine = _NoBackgroundOfficePreview();
      cache = ThumbnailCache(
        Directory('${temp.path}/named-picture-covers'),
        officePreviewEngine: engine,
      );
      final note = await office(
        fileName,
        officeZip({
          'mimetype': utf8.encode('application/octet-stream'),
          part: redPicture(70, 100, png: true),
        }),
      );
      final cover = await cache.getOrCreate(repository, note);
      expect(cover, isNotNull);
      final (width, height, red) = await inspectPng(cover!);
      expect(width, 240);
      expect(height, lessThanOrEqualTo(320));
      expect(red, greaterThan(1000));
      expect(
        (await ThumbnailCache.readCoverFacts(cover))!.aspect,
        closeTo(70 / 100, 1e-9),
      );
      // 한글 has a headless engine; the picture is used when it fails.
      expect(engine.calls, fileName.endsWith('.hwpx') ? 1 : 0);
    });
  }
}

/// An Office engine as on Android: Word·PowerPoint cannot be converted
/// without a window, and the headless preview a 한글 original may ask for
/// fails as when its engine is missing.
class _NoBackgroundOfficePreview extends OfficePreviewEngine {
  new() : super(isWindows: false, isAndroid: true);

  var calls = 0;

  @override
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) async {
    calls++;
    throw StateError('The preview engine is not available');
  }
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
