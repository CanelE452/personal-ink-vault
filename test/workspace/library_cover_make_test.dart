import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/office_preview.dart';
import '../utils/test_mock_channel_handlers.dart';

/// 「첫 쪽 표지 만들기」 (the user's correction of 2026-11-17): on Android a
/// Word·PowerPoint card without a first-page picture can have its cover
/// made by the conversion its import used to run.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late WorkspaceController controller;
  late bool closed;

  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('library-cover-make-');
    controller = WorkspaceController(
      await NoteRepository.open(
        Directory(p.join(temp.path, 'vault')),
        createFormatVersion: 2,
      ),
      directoryProvider: () async => Directory(p.join(temp.path, 'support')),
    );
    await controller.refresh();
    closed = false;
    stows.libraryPanelOpen.value = null;
    stows.libraryGrid.value = true;
    stows.librarySort.value = 'default';
  });

  tearDown(() async {
    if (!closed) {
      await controller.flush();
      controller.dispose();
      await controller.repository.close();
    }
    stows.libraryPanelOpen.value = null;
    for (var attempt = 0; ; attempt++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on PathAccessException {
        if (!Platform.isWindows || attempt == 19) rethrow;
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

  Future<void> until(
    WidgetTester tester,
    bool Function() ready,
    String reason,
  ) async {
    for (var i = 0; i < 40 && !ready(); i++) {
      await drain(tester);
    }
    expect(ready(), isTrue, reason: reason);
  }

  Future<void> closeWhilePumping(WidgetTester tester) async {
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        () async {
          await controller.flush();
          controller.dispose();
          await controller.repository.close();
        }().whenComplete(() => done = true),
      );
    });
    for (var i = 0; i < 80 && !done; i++) {
      await drain(tester);
    }
    closed = done;
  }

  Future<T> read<T>(WidgetTester tester, Future<T> Function() operation) async {
    var done = false;
    T? value;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      unawaited(
        operation().then(
          (result) {
            value = result;
            done = true;
          },
          onError: (Object error, StackTrace stack) {
            failure = error;
            trace = stack;
            done = true;
          },
        ),
      );
    });
    await until(tester, () => done, 'The read must finish.');
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return value as T;
  }

  Future<void> mount(
    WidgetTester tester,
    _CoverEngine engine, {
    ThumbnailCache Function(Directory)? covers,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: StudyWorkspace(
            controller: controller,
            officePreviewEngine: engine,
            thumbnailCacheFactory:
                covers ??
                (root) => ThumbnailCache(root, officePreviewEngine: engine),
          ),
        ),
      ),
    );
    await drain(tester);
  }

  Finder key(String value) => find.byKey(ValueKey(value));
  VaultNote listed(String id) =>
      controller.notes.singleWhere((note) => note.id == id);
  final make = key('library-note-cover-make');
  bool hasPicture(VaultNote note) => find
      .descendant(
        of: key('library-cover-${note.id}'),
        matching: find.byType(Image),
      )
      .evaluate()
      .isNotEmpty;

  Future<void> openMenu(WidgetTester tester, VaultNote note) async {
    await tester.tap(
      key('library-note-menu-${listed(note.id).revision.revisionId}'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> closeMenu(WidgetTester tester) async {
    await tester.tapAt(const Offset(1195, 795));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Uint8List zip(Map<String, List<int>> parts) {
    final archive = Archive();
    for (final MapEntry(key: name, value: bytes) in parts.entries) {
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  testWidgets(
    '첫 쪽 표지 만들기 appears only on Android office cards without a cover and runs the conversion',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await withOfficePreviewPdfium(tester, () async {
          final engine = _CoverEngine(
            (await tester.runAsync(() => officePreviewPdf(PdfColors.red)))!,
          );
          // A PowerPoint original without a picture inside, a 한글 one, and
          // a Word one whose own preview picture becomes its cover.
          final (deck, letter, report) = (await tester.runAsync(() async {
            final store = OfficeDocumentStore(controller.repository);
            final deck = await store.importDocument(
              title: '발표',
              fileName: '발표.pptx',
              bytes: zip({
                '[Content_Types].xml': utf8.encode('<Types/>'),
                'ppt/presentation.xml': utf8.encode('<presentation/>'),
              }),
            );
            final letter = await store.importDocument(
              title: '공문',
              fileName: '공문.hwpx',
              bytes: zip({'mimetype': utf8.encode('application/hwp+zip')}),
            );
            final report = await store.importDocument(
              title: '보고서',
              fileName: '보고서.docx',
              bytes: zip({
                'docProps/thumbnail.png': image.encodePng(
                  image.Image(width: 70, height: 100),
                ),
              }),
            );
            await controller.refresh();
            return (deck, letter, report);
          }))!;
          bool ready() =>
              [deck, letter, report].every(
                (note) =>
                    key('library-format-${note.id}').evaluate().isNotEmpty,
              ) &&
              hasPicture(report);

          // Windows makes Office covers in the background: no such row.
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          await mount(tester, engine);
          await until(tester, ready, 'The cards know their formats.');
          expect(hasPicture(deck), isFalse);
          await openMenu(tester, deck);
          expect(find.text('표지 변경'), findsOneWidget);
          expect(make, findsNothing);
          await closeMenu(tester);
          await tester.pumpWidget(const SizedBox());

          // On Android the PowerPoint card without a cover offers it.
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          await mount(tester, engine);
          await until(tester, ready, 'The cards know their formats.');
          await openMenu(tester, deck);
          expect(make, findsOneWidget);
          expect(
            find.descendant(of: make, matching: find.text('첫 쪽 표지 만들기')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: make,
              matching: find.byIcon(Icons.image_outlined),
            ),
            findsOneWidget,
          );
          await closeMenu(tester);
          // Not for 한글, which has its background engine, nor for a card
          // that already shows its first page.
          for (final note in [letter, report]) {
            await openMenu(tester, note);
            expect(find.text('표지 변경'), findsOneWidget, reason: note.title);
            expect(make, findsNothing, reason: note.title);
            await closeMenu(tester);
          }
          expect(engine.converted, isEmpty);

          // The row runs the conversion once; the card then shows the first
          // page and no longer offers it.
          await openMenu(tester, deck);
          await tester.tap(make);
          await until(
            tester,
            () => engine.converted.isNotEmpty && hasPicture(deck),
            'The conversion runs and the card shows its first page.',
          );
          expect(engine.converted, ['발표.pptx']);
          await openMenu(tester, deck);
          expect(find.text('표지 변경'), findsOneWidget);
          expect(make, findsNothing);
          await closeMenu(tester);
          expect(tester.takeException(), isNull);
        });
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (!closed) await closeWhilePumping(tester);
        debugDefaultTargetPlatformOverride = null;
      }
    },
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    '첫 쪽 표지 만들기 says so when the conversion fails or is cancelled',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await withOfficePreviewPdfium(tester, () async {
          final engine = _FailingCoverEngine();
          final deck = (await tester.runAsync(() async {
            final deck = await OfficeDocumentStore(controller.repository)
                .importDocument(
                  title: '발표',
                  fileName: '발표.pptx',
                  bytes: zip({
                    '[Content_Types].xml': utf8.encode('<Types/>'),
                    'ppt/presentation.xml': utf8.encode('<presentation/>'),
                  }),
                );
            await controller.refresh();
            return deck;
          }))!;
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          await mount(tester, engine);
          await until(
            tester,
            () => key('library-format-${deck.id}').evaluate().isNotEmpty,
            'The card knows its format.',
          );
          final message = find.text('첫 쪽 표지를 만들지 못했습니다');
          // The conversion fails, then is cancelled: each time the row says
          // so, and the card keeps no picture.
          for (final attempt in [1, 2]) {
            await openMenu(tester, deck);
            await tester.tap(make);
            await until(
              tester,
              () =>
                  engine.converted.length == attempt &&
                  message.evaluate().isNotEmpty,
              'Attempt $attempt is reported.',
            );
            expect(hasPicture(deck), isFalse);
            await until(
              tester,
              () => message.evaluate().isEmpty,
              'The message goes after a while.',
            );
          }
          expect(engine.converted, ['발표.pptx', '발표.pptx']);
          expect(tester.takeException(), isNull);
        });
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (!closed) await closeWhilePumping(tester);
        debugDefaultTargetPlatformOverride = null;
      }
    },
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'a newer edition arriving during the conversion does not receive the PDF',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await withOfficePreviewPdfium(tester, () async {
          final engine = _HeldCoverEngine(
            (await tester.runAsync(() => officePreviewPdf(PdfColors.red)))!,
          );
          final deck = (await tester.runAsync(() async {
            final deck = await OfficeDocumentStore(controller.repository)
                .importDocument(
                  title: '발표',
                  fileName: '발표.pptx',
                  bytes: zip({
                    '[Content_Types].xml': utf8.encode('<Types/>'),
                    'ppt/presentation.xml': utf8.encode('<presentation/>'),
                  }),
                );
            await controller.refresh();
            return deck;
          }))!;
          final first = (await read(
            tester,
            () => controller.repository.heads(deck.sourceEntityId!),
          )).single;
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          await mount(tester, engine);
          await until(
            tester,
            () => key('library-format-${deck.id}').evaluate().isNotEmpty,
            'The card knows its format.',
          );
          await openMenu(tester, deck);
          await tester.tap(make);
          await until(
            tester,
            () => engine.converted.isNotEmpty,
            'The conversion screen is open.',
          );

          // A newer original arrives while the conversion screen is open (a
          // sync pull, say); then the conversion of the first one finishes.
          final newer = await read(
            tester,
            () => controller.repository.commit(
              entityId: deck.sourceEntityId!,
              kind: EntityKind.attachment,
              ownerNoteId: deck.id,
              files: {
                '발표.pptx': zip({
                  '[Content_Types].xml': utf8.encode('<Types/>'),
                  'ppt/presentation.xml': utf8.encode('<presentation v="2"/>'),
                }),
              },
              parentRevisionIds: [first.revisionId],
            ),
          );
          engine.release.complete();
          await until(
            tester,
            () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
            'The conversion is over.',
          );
          final (heads, onFirst, onNewer) = await read(tester, () async {
            final store = OfficeDocumentStore(controller.repository);
            return (
              await controller.repository.heads(deck.sourceEntityId!),
              await store.readDerivedPdfVariants(deck, first),
              await store.readDerivedPdfVariants(deck, newer),
            );
          });
          expect(heads.single.revisionId, newer.revisionId);
          // The PDF belongs to the original it was made from; the newer
          // edition has none, so its card still offers the row.
          expect(onFirst, hasLength(1));
          expect(onNewer, isEmpty);
          await openMenu(tester, deck);
          expect(make, findsOneWidget);
          await closeMenu(tester);
          expect(engine.converted, ['발표.pptx']);
          expect(tester.takeException(), isNull);
        });
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (!closed) await closeWhilePumping(tester);
        debugDefaultTargetPlatformOverride = null;
      }
    },
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    '첫 쪽 표지 만들기 does not convert an edition that already has its PDF',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await withOfficePreviewPdfium(tester, () async {
          final pdf = (await tester.runAsync(
            () => officePreviewPdf(PdfColors.red),
          ))!;
          final engine = _CoverEngine(pdf);
          final deck = (await tester.runAsync(() async {
            final store = OfficeDocumentStore(controller.repository);
            final deck = await store.importDocument(
              title: '발표',
              fileName: '발표.pptx',
              bytes: zip({
                '[Content_Types].xml': utf8.encode('<Types/>'),
                'ppt/presentation.xml': utf8.encode('<presentation/>'),
              }),
            );
            await store.keepFirstPdf(deck, pdfBytes: pdf, pageCount: 1);
            await controller.refresh();
            return deck;
          }))!;
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          // A cover that has not been drawn yet, so the row is offered.
          await mount(tester, engine, covers: _NoCovers.new);
          await until(
            tester,
            () => key('library-format-${deck.id}').evaluate().isNotEmpty,
            'The card knows its format.',
          );
          await openMenu(tester, deck);
          await tester.tap(make);
          final message = find.text('이미 첫 쪽 표지가 있습니다');
          await until(
            tester,
            () => message.evaluate().isNotEmpty,
            'The row says the first page is already there.',
          );
          expect(engine.converted, isEmpty);
          expect(tester.takeException(), isNull);
        });
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (!closed) await closeWhilePumping(tester);
        debugDefaultTargetPlatformOverride = null;
      }
    },
    skip: !officePreviewPdfiumAvailable,
  );
}

/// The conversion screen stays open until [release] completes.
final class _HeldCoverEngine extends _CoverEngine {
  new(super.pdf);

  final release = Completer<void>();

  @override
  Future<({Uint8List bytes, int pageCount, String engineVersion})?>
  convertToPdf({required String fileName, required Uint8List original}) async {
    converted.add(fileName);
    await release.future;
    return (bytes: pdf, pageCount: 1, engineVersion: 'cover-test');
  }
}

/// A cover cache that has drawn nothing yet.
final class _NoCovers extends ThumbnailCache {
  new(super.root);

  @override
  Future<String?> coverKey(NoteRepository repository, VaultNote note) async =>
      null;
}

/// An Office engine as on Android: Word·PowerPoint are converted only
/// through the conversion screen ([convertToPdf], recorded here), and the
/// headless preview a 한글 cover asks for is missing.
final class _CoverEngine extends OfficePreviewEngine {
  new(this.pdf) : super(isWindows: false, isAndroid: true);

  final Uint8List pdf;
  final converted = <String>[];

  @override
  Future<({Uint8List bytes, int pageCount, String engineVersion})?>
  convertToPdf({required String fileName, required Uint8List original}) async {
    converted.add(fileName);
    return (bytes: pdf, pageCount: 1, engineVersion: 'cover-test');
  }

  @override
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) async => throw StateError('No headless engine on this device');
}

/// The conversion screen fails the first time and is cancelled after that.
final class _FailingCoverEngine extends _CoverEngine {
  new() : super(Uint8List(0));

  @override
  Future<({Uint8List bytes, int pageCount, String engineVersion})?>
  convertToPdf({required String fileName, required Uint8List original}) async {
    converted.add(fileName);
    if (converted.length == 1) throw StateError('No conversion screen');
    return null;
  }
}
