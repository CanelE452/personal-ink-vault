import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/pdf_note_original.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../office/office_original_preview_test.dart'
    show
        officePreviewPdf,
        officePreviewPdfiumAvailable,
        officePreviewUntil,
        withOfficePreviewPdfium;
import '../utils/test_mock_channel_handlers.dart';

// Kept in its own file: inside library_flow_test.dart this flow made later,
// unrelated tests there fail at random (bookmarks, quick note, home creation).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late WorkspaceController controller;
  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('pdf-original-remake-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    await controller.refresh();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    for (var attempt = 0; ; attempt++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on PathAccessException catch (error) {
        if (!Platform.isWindows ||
            error.osError?.errorCode != 32 ||
            attempt == 19) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  // drain and readWhilePumping are the helpers of library_flow_test.dart.
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

  testWidgets(
    'a kept original makes a new PDF note and leaves the first note as it is',
    (tester) => withOfficePreviewPdfium(tester, () async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final inbox = StudyWorkspace.pendingDocumentImport;
      final starter = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'Lecture slides',
      );
      final (file, oldPdf, newPdf) = await readWhilePumping(
        tester,
        () async => (
          await File('${temp.path}/${starter.fileName}')
              .writeAsBytes(starter.bytes),
          await officePreviewPdf(PdfColors.red),
          await officePreviewPdf(PdfColors.blue),
        ),
      );
      final converter = _Converter(temp, oldPdf);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: StudyWorkspace(
              controller: controller,
              officePreviewEngine: converter,
              thumbnailCacheFactory: _NoCoverCache.new,
            ),
          ),
        ),
      );
      try {
        inbox.enqueue(file.path, sharedRequestId: newId());
        final choice = find.text('PDF 필기용');
        await officePreviewUntil(
          tester,
          () => choice.hitTestable().evaluate().isNotEmpty,
          'The import choice must be presented.',
        );
        await tester.runAsync(() => tester.tap(choice));
        final remake = find.byKey(const ValueKey('pdf-remake-from-original'));
        bool remakeReady() =>
            remake.hitTestable().evaluate().isNotEmpty &&
            tester.widget<IconButton>(remake).onPressed != null &&
            controller.pendingPdfPath == null &&
            !controller.inkBusy;
        await officePreviewUntil(
          tester,
          remakeReady,
          'A PDF note with a kept original offers to convert it again.',
        );
        final first = controller.activeSession!.note;

        Future<void> convertAgain() async {
          await tester.runAsync(() => tester.tap(remake));
          final confirm = find.text('새 노트로 만들기');
          await officePreviewUntil(
            tester,
            () => confirm.hitTestable().evaluate().isNotEmpty,
            'Converting again asks first.',
          );
          await tester.runAsync(() => tester.tap(confirm));
        }

        await convertAgain();
        await officePreviewUntil(
          tester,
          () => find
              .text('새 엔진으로 만든 PDF가 지금 PDF와 같아 새 노트를 만들지 않았습니다.')
              .evaluate()
              .isNotEmpty,
          'An identical PDF does not make another note.',
        );
        expect(converter.calls, 2);
        expect(controller.activeSession?.note.id, first.id);

        converter.output = newPdf;
        await officePreviewUntil(
          tester,
          remakeReady,
          'The action is available again after the notice.',
        );
        await convertAgain();
        await officePreviewUntil(
          tester,
          () =>
              controller.activeSession?.note.id != first.id &&
              find.byType(Editor).evaluate().isNotEmpty &&
              remakeReady(),
          'A different PDF opens as a new note that keeps the original too.',
        );
        expect(converter.calls, 3);
        final second = controller.activeSession!.note;
        expect(second.title, '${first.title} (새 엔진)');
        expect(second.documentKind, VaultDocumentKind.pdf);
        final (notes, sources, kept) = await readWhilePumping(tester, () async {
          final repo = controller.repository;
          Future<Uint8List> source(VaultNote note) async {
            final head = (await repo.heads(note.sourceEntityId!)).single;
            return (await repo.readFiles(head)).values.single;
          }

          final originals = PdfNoteOriginalStore(repo);
          return (
            await controller.store.list(),
            [await source(first), await source(second)],
            [await originals.read(first), await originals.read(second)],
          );
        });
        expect(
          notes.map((note) => note.id),
          unorderedEquals([first.id, second.id]),
        );
        expect(
          notes.singleWhere((note) => note.id == first.id).revision.revisionId,
          first.revision.revisionId,
        );
        expect(sources, [oldPdf, newPdf]);
        for (final original in kept) {
          expect(original!.fileName, starter.fileName);
          expect(original.bytes, starter.bytes);
          expect(original.engineVersion, 'library-test');
        }
      } finally {
        inbox.value = null;
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
        // As library_flow_test's closeOfficeFlow: flushing needs frames to finish.
        await readWhilePumping(tester, () async {
          await controller.flush();
          controller.dispose();
          await controller.repository.close();
        });
        debugDefaultTargetPlatformOverride = null;
      }
    }),
    skip: !officePreviewPdfiumAvailable,
  );
}

final class _Converter extends OfficePreviewEngine {
  new(this.directory, this.output);
  final Directory directory;
  Uint8List output;
  var calls = 0;

  @override
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) async {
    calls++;
    final pdf = await File('${directory.path}/converted-$sessionId.pdf')
        .writeAsBytes(output);
    final input = await File(sourcePath).readAsBytes();
    return OfficePreviewResult(
      pdfPath: pdf.path,
      pdfSha256: sha256.convert(output).toString(),
      pageCount: 1,
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
