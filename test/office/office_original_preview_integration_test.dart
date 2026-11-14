import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:pdf/pdf.dart' show PdfColor, PdfColors;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/toolbar/toolbar.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/office_view_state.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_original_preview.dart';
import 'package:saber/pages/office/office_workspace.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

import '../utils/test_editor.dart';
import '../utils/test_mock_channel_handlers.dart';
import 'annotation_store_test.dart' show annotationOfficeFile;
import 'office_original_preview_test.dart'
    show
        OfficePreviewDocumentTracker,
        expectOfficePreviewColor,
        officePreviewDocumentsClosed,
        officePreviewPdf,
        officePreviewPdfiumAvailable,
        officePreviewRead,
        officePreviewUntil,
        withOfficePreviewPdfium;
import 'office_workspace_test.dart' show FixtureOfficeEngine;

Future<void>? _previewFonts;

Future<void> _loadPreviewFonts() => _previewFonts ??= () async {
  for (final entry in const {
    'OfficePreviewTestNoto': 'build/native/fonts/NotoSansCJKkr-Regular.otf',
    'MaterialIcons': 'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
  }.entries) {
    final font = FontLoader(entry.key);
    font.addFont(() async {
      final bytes = await File(entry.value).readAsBytes();
      return ByteData.sublistView(bytes);
    }());
    await font.load();
  }
}();

Future<void> _withFixture(
  WidgetTester tester,
  Future<void> Function(_PreviewFixture fixture) body, {
  OfficeTemplateKind? template,
}) => withOfficePreviewPdfium(tester, () async {
  await officePreviewRead(tester, _loadPreviewFonts);
  final fixture = await officePreviewRead(
    tester,
    () => _PreviewFixture.create(template: template),
  );
  try {
    await body(fixture);
  } finally {
    if (find.byType(Editor).evaluate().isNotEmpty) {
      await officePreviewUntil(
        tester,
        () => !fixture.busy,
        'The mounted annotation editor must finish loading before teardown',
      );
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    await officePreviewDocumentsClosed(tester);
    await officePreviewRead(tester, fixture.close);
  }
});

Future<void> _mount(
  WidgetTester tester,
  _PreviewFixture fixture,
  _CountingEdit edit,
  _CountingPreview preview, {
  VoidCallback? onBack,
  NoteRepository? repository,
}) => tester.pumpWidget(
  TranslationProvider(
    child: MaterialApp(
      theme: ThemeData(fontFamily: 'OfficePreviewTestNoto'),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('office-original-screen-capture'),
          child: Material(
            child: OfficeWorkspace(
              key: const ValueKey('stable-original-workspace'),
              repository: repository ?? fixture.repository,
              note: fixture.note,
              engine: edit,
              previewEngine: preview,
              onBusyChanged: (busy) => fixture.busy = busy,
              onBack: onBack ?? () {},
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _load(WidgetTester tester) async {
  final action = find.byKey(const ValueKey('office-original-preview-load'));
  await officePreviewUntil(
    tester,
    () =>
        action.evaluate().isNotEmpty &&
        tester.widget<ButtonStyleButton>(action).onPressed != null,
    'An original without a PDF must offer an explicit read-only preview',
  );
  await tester.ensureVisible(action);
  await tester.runAsync(() async {
    await tester.tap(action);
  });
}

Future<OfficeOriginalPreview> _shown(WidgetTester tester, String pdfSha) async {
  await officePreviewUntil(
    tester,
    () =>
        find.byType(OfficeOriginalPreview).evaluate().isNotEmpty &&
        tester
            .widget<OfficeOriginalPreview>(find.byType(OfficeOriginalPreview))
            .sourceKey
            .contains(pdfSha),
    'The rendered preview must belong to the selected PDF',
  );
  return tester.widget<OfficeOriginalPreview>(
    find.byType(OfficeOriginalPreview),
  );
}

Future<void> _select(WidgetTester tester, String revision) async {
  final selector = find.byKey(const ValueKey('office-edition-selector'));
  await officePreviewUntil(
    tester,
    () =>
        selector.evaluate().isNotEmpty &&
        tester.widget<DropdownButton<String>>(selector).onChanged != null,
    'The edition selector must be ready',
  );
  final callback = tester.widget<DropdownButton<String>>(selector).onChanged!;
  await tester.runAsync(() async {
    callback(revision);
  });
}

Future<void> _capture(WidgetTester tester, double width) async {
  final raster = find.descendant(
    of: find.byType(OfficeOriginalPreview),
    matching: find.byType(RawImage),
  );
  await officePreviewUntil(
    tester,
    () => raster.evaluate().any(
      (element) => (element.widget as RawImage).image != null,
    ),
    'The selected PDF must have a real page raster before its screen is captured',
  );
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('office-original-screen-capture')),
  );
  await officePreviewRead(tester, () async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File(
        'build/validation/office-word-fidelity/original-preview-${width.toInt()}.png',
      ).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    } finally {
      image.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  for (final width in [1000.0, 320.0]) {
    testWidgets(
      'the original tab renders selected saved editions without creating revisions at $width px',
      (tester) => _withFixture(tester, (fixture) async {
        await tester.binding.setSurfaceSize(Size(width, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final red = await officePreviewRead(
          tester,
          () => fixture.paired(PdfColors.red),
        );
        final blue = await officePreviewRead(
          tester,
          () => fixture.paired(PdfColors.blue),
        );
        final before = await officePreviewRead(tester, fixture.revisionCount);
        final sourceFiles = await officePreviewRead(
          tester,
          () => fixture.repository.readFiles(blue.revision),
        );
        final edit = _CountingEdit();
        final preview = _CountingPreview((_, _) async {
          throw StateError('A saved PDF must not invoke original conversion');
        });
        await _mount(tester, fixture, edit, preview);
        final current = await _shown(tester, blue.pdfSha256!);
        expect(current.pdfBytes, blue.pdfBytes);
        expect(current.sourceKey, contains(fixture.repository.vaultId));
        expect(current.sourceKey, contains(fixture.note.id));
        expect(current.sourceKey, contains(blue.revision.revisionId));
        await expectOfficePreviewColor(tester, red: false);
        final editOriginal = find.byKey(const ValueKey('office-edit-original'));
        final startInk = find.byKey(const ValueKey('office-preview-pdf'));
        final renderedPage = find.descendant(
          of: find.byType(OfficeOriginalPreview),
          matching: find.byType(PdfPageView),
        );
        final findReplace = find.byKey(
          const ValueKey('office-edit-docx-find-replace'),
        );
        expect(editOriginal.hitTestable(), findsOneWidget);
        expect(startInk.hitTestable(), findsOneWidget);
        expect(renderedPage.hitTestable(), findsOneWidget);
        expect(findReplace, findsNothing);
        final advanced = find.text('세부 편집 도구');
        await tester.ensureVisible(advanced);
        await tester.tap(advanced);
        await tester.pumpAndSettle();
        expect(findReplace, findsOneWidget);
        await tester.tap(advanced);
        await tester.pumpAndSettle();
        expect(findReplace, findsNothing);
        await _select(tester, red.revision.revisionId);
        final historical = await _shown(tester, red.pdfSha256!);
        expect(historical.pdfBytes, red.pdfBytes);
        expect(historical.sourceKey, isNot(current.sourceKey));
        expect(historical.sourceKey, contains(red.revision.revisionId));
        await expectOfficePreviewColor(tester, red: true);
        await _select(tester, blue.revision.revisionId);
        expect(
          (await _shown(tester, blue.pdfSha256!)).sourceKey,
          current.sourceKey,
        );
        await expectOfficePreviewColor(tester, red: false);
        await _capture(tester, width);
        expect(await officePreviewRead(tester, fixture.revisionCount), before);
        expect(
          await officePreviewRead(
            tester,
            () => fixture.repository.readFiles(blue.revision),
          ),
          sourceFiles,
        );
        expect(await officePreviewRead(tester, fixture.inkRevisions), isEmpty);
        expect(edit.calls, 0);
        expect(preview.calls, 0);
        expect(tester.takeException(), isNull);
      }),
      skip: !officePreviewPdfiumAvailable,
    );
  }

  testWidgets(
    'an imported original creates an explicit private preview without publishing PDF or ink',
    (tester) => _withFixture(tester, (fixture) async {
      final before = await officePreviewRead(tester, fixture.revisionCount);
      final source = await officePreviewRead(tester, fixture.currentSource);
      final original = await officePreviewRead(
        tester,
        () => fixture.repository.readFiles(source),
      );
      final edit = _CountingEdit();
      final preview = _CountingPreview(
        (path, id) => fixture.previewResult(path, id, PdfColors.red),
      );
      await _mount(tester, fixture, edit, preview);
      await officePreviewUntil(
        tester,
        () => find
            .byKey(const ValueKey('office-original-preview-load'))
            .evaluate()
            .isNotEmpty,
        'The imported original must load without launching a converter',
      );
      expect(preview.calls, 0);
      expect(find.byType(OfficeOriginalPreview), findsNothing);
      await _load(tester);
      await officePreviewUntil(
        tester,
        () => preview.result != null,
        'The explicit preview must finish its private PDF conversion',
      );
      await _shown(tester, preview.result!.pdfSha256);
      await officePreviewUntil(
        tester,
        () => (preview.result! as _OwnedPreviewResult).disposalCalls == 1,
        'The private output must be released after its verified bytes are copied',
      );
      expect(File(preview.result!.pdfPath).existsSync(), isFalse);
      await expectOfficePreviewColor(tester, red: true);
      expect(preview.calls, 1);
      expect(edit.calls, 0);
      expect(await officePreviewRead(tester, fixture.revisionCount), before);
      expect(await officePreviewRead(tester, fixture.inkRevisions), isEmpty);
      expect(
        await officePreviewRead(
          tester,
          () => fixture.repository.readFiles(source),
        ),
        original,
      );
      expect(
        (await officePreviewRead(tester, fixture.currentSource)).revisionId,
        source.revisionId,
      );
      expect(tester.takeException(), isNull);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'explicit PDF annotation reuses a private preview without changing the source revision',
    (tester) => _withFixture(tester, (fixture) async {
      final source = await officePreviewRead(tester, fixture.currentSource);
      final before = await officePreviewRead(tester, fixture.revisionCount);
      final beforeIds = (await officePreviewRead(
        tester,
        fixture.repository.revisions,
      )).map((record) => record.revisionId).toSet();
      final original = await officePreviewRead(
        tester,
        () => fixture.repository.readFiles(source),
      );
      final edit = _CountingEdit();
      final preview = _CountingPreview(
        (path, id) => fixture.previewResult(path, id, PdfColors.red),
      );
      var backs = 0;
      await _mount(tester, fixture, edit, preview, onBack: () => backs++);
      await _load(tester);
      await officePreviewUntil(
        tester,
        () => preview.result != null,
        'The explicit preview must be ready before annotation',
      );
      await _shown(tester, preview.result!.pdfSha256);
      final viewed = preview.result! as _OwnedPreviewResult;
      await officePreviewUntil(
        tester,
        () => viewed.disposalCalls == 1 && !File(viewed.pdfPath).existsSync(),
        'Annotation must reuse cached bytes after the native preview is released',
      );
      expect(await officePreviewRead(tester, fixture.revisionCount), before);
      final annotate = find.byKey(const ValueKey('office-preview-pdf'));
      await tester.ensureVisible(annotate);
      await officePreviewUntil(
        tester,
        () => tester.widget<ButtonStyleButton>(annotate).onPressed != null,
        'Explicit annotation must be available after read-only conversion',
      );
      await tester.runAsync(() async {
        await tester.tap(annotate);
      });
      await officePreviewUntil(
        tester,
        () => tester
            .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
            .selected
            .contains(true),
        'The explicit action must open PDF annotation mode',
      );
      await officePreviewUntil(
        tester,
        () => find.byType(Editor).evaluate().isNotEmpty && !fixture.busy,
        'The actual annotation editor must finish its public busy lifecycle',
      );
      expect(
        (PdfrxEntryFunctions.instance as OfficePreviewDocumentTracker)
            .filePaths,
        isNotEmpty,
        reason: 'The annotation editor must really open its saved PDF file',
      );
      final unchanged = await officePreviewRead(
        tester,
        () => fixture.documents.readLatest(fixture.note),
      );
      expect(unchanged.revision.revisionId, source.revisionId);
      expect(unchanged.originalBytes, fixture.original);
      expect(unchanged.pdfBytes, isNull);
      final variant = (await officePreviewRead(
        tester,
        () => fixture.documents.readPdfVariants(fixture.note, unchanged),
      )).single;
      expect(variant.sourceRevisionId, source.revisionId);
      expect(variant.pdfSha256, viewed.pdfSha256);
      expect(variant.revision.kind, EntityKind.attachment);
      expect(variant.revision.ownerNoteId, fixture.note.id);
      expect(variant.revision.entityId, isNot(source.entityId));
      expect(variant.revision.parentRevisionIds, isEmpty);
      expect(variant.revision.baseRefs, {
        source.entityId: [source.revisionId],
      });
      expect(variant.revision.blobs, hasLength(1));
      expect(variant.revision.blobs.values.single.hash, viewed.pdfSha256);
      expect(
        await officePreviewRead(
          tester,
          () => fixture.documents.readPdfVariantBytes(
            fixture.note,
            unchanged,
            variant,
          ),
        ),
        viewed.expectedBytes,
      );
      expect(
        await officePreviewRead(tester, fixture.revisionCount),
        before + 1,
        reason: 'Opening PDF annotation publishes only the derived attachment',
      );
      final bindingId = variant.bindingId;
      expect(
        await officePreviewRead(
          tester,
          () => fixture.repository.heads(bindingId),
        ),
        isEmpty,
      );
      final editor = tester.state<EditorState>(find.byType(Editor));
      final pages = editor.coreInfo.pages;
      const pdfPages = 1;
      expect(
        pages,
        hasLength(pdfPages + 1),
        reason: 'The PDF editor retains one trailing blank writing page',
      );
      for (final page in pages) {
        expect(page.strokes, isEmpty);
        expect(page.laserStrokes, isEmpty);
        expect(page.images, isEmpty);
        expect(page.quill.controller.document.isEmpty(), isTrue);
      }
      for (var index = 0; index < pdfPages; index++) {
        final page = pages[index];
        expect(page.backgroundImage, isA<PdfEditorImage>());
        final background = page.backgroundImage! as PdfEditorImage;
        expect(background.pdfPage, index);
        expect(background.pageIndex, index);
        final bytes =
            background.pdfBytes ??
            await officePreviewRead(tester, background.pdfFile!.readAsBytes);
        expect(bytes, viewed.expectedBytes);
        expect(sha256.convert(bytes!).toString(), viewed.pdfSha256);
      }
      expect(pages.last.backgroundImage, isNull);
      expect(pages.last.isEmpty, isTrue);
      expect(editor.history.canUndo, isFalse);
      final added =
          (await officePreviewRead(tester, fixture.repository.revisions))
              .where((record) => !beforeIds.contains(record.revisionId))
              .map((record) => record.revisionId)
              .toSet();
      expect(added, {variant.revision.revisionId});
      expect(
        await officePreviewRead(
          tester,
          () => fixture.repository.readFiles(source),
        ),
        original,
      );
      expect(
        preview.calls,
        1,
        reason: 'Explicit annotation must reuse the verified private PDF',
      );
      expect(edit.calls, 0);
      await officePreviewRead(
        tester,
        () => tester
            .state<OfficeWorkspaceState>(find.byType(OfficeWorkspace))
            .save(),
      );
      expect(
        await officePreviewRead(tester, fixture.revisionCount),
        before + 1,
      );
      final back = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '문서 목록으로',
      );
      await officePreviewUntil(
        tester,
        () => tester.widget<IconButton>(back).onPressed != null,
        'The unchanged annotation must be ready to close',
      );
      await tester.runAsync(() async {
        await tester.tap(back);
      });
      await officePreviewUntil(
        tester,
        () => backs == 1,
        'Back must return without publishing an empty annotation snapshot',
      );
      expect(
        await officePreviewRead(tester, fixture.revisionCount),
        before + 1,
      );
      expect(
        await officePreviewRead(
          tester,
          () => fixture.repository.heads(bindingId),
        ),
        isEmpty,
      );
      expect(
        (await officePreviewRead(tester, fixture.currentSource)).revisionId,
        source.revisionId,
      );
      final view = await officePreviewRead(
        tester,
        OfficeViewStore(fixture.repository, fixture.note.id).load,
      );
      expect(view?.sourceRevisionId, source.revisionId);
      expect(view?.bindingId, bindingId);
      expect(view?.pdfMode, isTrue);
      expect(view?.pageId, pages.first.pageId);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'receiving a different Office PDF preserves the active ink until selection',
    (tester) => _withFixture(tester, (fixture) async {
      final (source, red, blue, redBytes, blueBytes) = await officePreviewRead(
        tester,
        () async {
          final repo = fixture.repository;
          final source = await fixture.documents.readLatest(fixture.note);
          final redBytes = await officePreviewPdf(PdfColors.red);
          final blueBytes = await officePreviewPdf(PdfColors.blue);
          final peer = await NoteRepository.open(
            Directory('${fixture.directory.path}/remote'),
            vaultId: repo.vaultId,
            createFormatVersion: 2,
          );
          try {
            for (final record in await repo.revisions()) {
              await peer.importRevision(
                record,
                blobsByHash: {
                  for (final ref in record.blobs.values)
                    ref.hash: await repo.readBlob(ref.hash),
                },
              );
            }
            final remoteDocuments = OfficeDocumentStore(peer);
            final blue = await remoteDocuments.commitDerivedPdf(
              await remoteDocuments.beginEdit(fixture.note),
              pdfBytes: blueBytes,
              pageCount: 1,
            );
            final red = await fixture.documents.commitDerivedPdf(
              await fixture.documents.beginEdit(fixture.note),
              pdfBytes: redBytes,
              pageCount: 1,
            );
            return (source, red, blue, redBytes, blueBytes);
          } finally {
            await peer.close();
          }
        },
      );
      expect(red.pdfSha256, isNot(blue.pdfSha256));
      expect(red.bindingId, isNot(blue.bindingId));
      final preview = _CountingPreview((_, _) async {
        throw StateError('A saved variant must not trigger another conversion');
      });
      await _mount(tester, fixture, _CountingEdit(), preview);
      final open = find.byKey(const ValueKey('office-preview-pdf'));
      await officePreviewUntil(
        tester,
        () =>
            open.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(open).onPressed != null,
        'The original must offer its already-saved PDF variant',
      );
      await tester.ensureVisible(open);
      await tester.runAsync(() async {
        await tester.tap(open);
      });
      final editor = find.byType(Editor);
      await officePreviewUntil(
        tester,
        () => editor.evaluate().isNotEmpty && !fixture.busy,
        'The first saved variant must open in the annotation editor',
      );
      final first = tester.state<EditorState>(editor);
      Future<Uint8List> backgroundBytes(EditorState editor) async {
        final background =
            editor.coreInfo.pages.first.backgroundImage! as PdfEditorImage;
        return background.pdfBytes ?? await background.pdfFile!.readAsBytes();
      }

      expect(
        await officePreviewRead(tester, () => backgroundBytes(first)),
        redBytes,
      );
      first.drawTestStroke();
      await officePreviewRead(
        tester,
        () => fixture.repository.importRevision(
          blue.revision,
          blobsByHash: {blue.pdfSha256: blueBytes},
        ),
      );
      final selector = find.byKey(
        const ValueKey('office-pdf-variant-selector'),
      );
      await officePreviewUntil(
        tester,
        () => selector.evaluate().isNotEmpty && !fixture.busy,
        'The received PDF must be offered beside the active variant',
      );
      final dropdown = tester.widget<DropdownButton<String>>(selector);
      expect(dropdown.items!.map((item) => item.value).toSet(), {
        red.bindingId,
        blue.bindingId,
      });
      expect(dropdown.value, red.bindingId);
      expect(tester.state<EditorState>(editor), same(first));
      expect(first.coreInfo.pages.first.strokes, isNotEmpty);
      await tester.runAsync(() async {
        dropdown.onChanged!(blue.bindingId);
      });
      await officePreviewUntil(
        tester,
        () =>
            editor.evaluate().isNotEmpty &&
            !identical(tester.state<EditorState>(editor), first) &&
            !fixture.busy,
        'Explicit selection must save the draft and open the received PDF',
      );
      final second = tester.state<EditorState>(editor);
      expect(
        await officePreviewRead(tester, () => backgroundBytes(second)),
        blueBytes,
      );
      expect(second.coreInfo.pages.first.strokes, isEmpty);
      final (saved, untouched, head) = await officePreviewRead(
        tester,
        () async => (
          await fixture.repository.heads(red.bindingId),
          await fixture.repository.heads(blue.bindingId),
          await fixture.currentSource(),
        ),
      );
      expect(saved.single.kind, EntityKind.ink);
      expect(saved.single.deviceId, fixture.repository.deviceId);
      expect(untouched, isEmpty);
      expect(head.revisionId, source.revision.revisionId);
      expect(preview.calls, 0);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'cancelled private conversion can be retried without publishing the original',
    (tester) => _withFixture(tester, (fixture) async {
      final before = await officePreviewRead(tester, fixture.revisionCount);
      final edit = _CountingEdit();
      var attempt = 0;
      final preview = _CountingPreview((path, id) async {
        if (++attempt == 1) return null;
        return fixture.previewResult(path, id, PdfColors.blue);
      });
      await _mount(tester, fixture, edit, preview);
      await _load(tester);
      await officePreviewUntil(
        tester,
        () =>
            preview.calls == 1 &&
            find
                .byKey(const ValueKey('office-original-preview-load'))
                .evaluate()
                .isNotEmpty &&
            tester
                    .widget<ButtonStyleButton>(
                      find.byKey(
                        const ValueKey('office-original-preview-load'),
                      ),
                    )
                    .onPressed !=
                null,
        'Cancellation must leave an explicit retry available',
      );
      expect(find.byType(OfficeOriginalPreview), findsNothing);
      expect(await officePreviewRead(tester, fixture.revisionCount), before);
      await _load(tester);
      await officePreviewUntil(
        tester,
        () => preview.result != null,
        'The retry must deliver its private PDF',
      );
      await _shown(tester, preview.result!.pdfSha256);
      await expectOfficePreviewColor(tester, red: false);
      expect(preview.calls, 2);
      expect(edit.calls, 0);
      expect(await officePreviewRead(tester, fixture.revisionCount), before);
      expect(await officePreviewRead(tester, fixture.inkRevisions), isEmpty);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'a late private preview never replaces a different note at the same workspace slot',
    (tester) => _withFixture(tester, (fixture) async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final edit = _CountingEdit();
      final preview = _CountingPreview((path, id) async {
        final result = await fixture.previewResult(path, id, PdfColors.red);
        entered.complete();
        await release.future;
        return result;
      });
      try {
        await _mount(tester, fixture, edit, preview);
        await _load(tester);
        await officePreviewUntil(
          tester,
          () => entered.isCompleted,
          'The original note conversion must be pending',
        );
        final blue = await officePreviewRead(tester, () async {
          fixture.note = await fixture.documents.importDocument(
            title: 'Different original',
            fileName: 'different.docx',
            bytes: fixture.original,
          );
          return fixture.paired(PdfColors.blue);
        });
        final before = await officePreviewRead(tester, fixture.revisionCount);
        await _mount(tester, fixture, edit, preview);
        final current = await _shown(tester, blue.pdfSha256!);
        expect(current.sourceKey, contains(fixture.note.id));
        await expectOfficePreviewColor(tester, red: false);
        release.complete();
        await officePreviewRead(
          tester,
          () => tester
              .state<OfficeWorkspaceState>(find.byType(OfficeWorkspace))
              .save(),
        );
        expect((preview.result! as _OwnedPreviewResult).disposalCalls, 1);
        expect(File(preview.result!.pdfPath).existsSync(), isFalse);
        expect(
          (await _shown(tester, blue.pdfSha256!)).sourceKey,
          current.sourceKey,
        );
        await expectOfficePreviewColor(tester, red: false);
        expect(preview.calls, 1);
        expect(edit.calls, 0);
        expect(await officePreviewRead(tester, fixture.revisionCount), before);
        expect(await officePreviewRead(tester, fixture.inkRevisions), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'Android opens a new presentation in the ordinary ink editor from one tap',
    (
      tester,
    ) => _withFixture(tester, template: OfficeTemplateKind.presentation, (
      fixture,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final release = Completer<void>();
      final edit = _CountingEdit();
      final preview = _CountingPreview((path, id) async {
        await release.future;
        return fixture.previewResult(path, id, PdfColors.red);
      });
      final action = find.byKey(const ValueKey('office-preview-pdf'));
      final mode = find.byType(SegmentedButton<bool>);
      final preparing = find.byKey(const ValueKey('office-pdf-preparing'));
      try {
        await _mount(tester, fixture, edit, preview);
        await officePreviewUntil(
          tester,
          () => action.hitTestable().evaluate().isNotEmpty,
          'The PDF ink action must be visible immediately on a phone.',
        );
        for (final label in ['찾아 바꾸기', '개체 겹침 순서', '도형 문단 정렬']) {
          expect(find.text(label), findsNothing);
        }
        expect(find.text('세부 편집 도구'), findsOneWidget);
        expect(mode.hitTestable(), findsOneWidget);
        await tester.runAsync(() => tester.tap(action));
        await officePreviewUntil(
          tester,
          () => preview.calls == 1,
          'The conversion must begin without opening the original editor.',
        );
        expect(preparing, findsOneWidget);
        release.complete();
        final editor = find.byType(Editor);
        final toolbar = find.descendant(
          of: editor,
          matching: find.byType(Toolbar),
        );
        await officePreviewUntil(
          tester,
          () => toolbar.hitTestable().evaluate().isNotEmpty && !fixture.busy,
          'The usual drawing tools must become usable without a second action.',
        );
        expect(tester.widget<Toolbar>(toolbar).readOnly, isFalse);
        final state = tester.state<EditorState>(editor);
        expect(
          state.coreInfo.pages.first.backgroundImage,
          isA<PdfEditorImage>(),
        );
        expect(preparing, findsNothing);
        expect(mode.hitTestable(), findsOneWidget);
        expect(tester.widget<SegmentedButton<bool>>(mode).selected, {true});
        final source = find.descendant(of: mode, matching: find.text('원본'));
        await tester.runAsync(() => tester.tap(source));
        await officePreviewUntil(
          tester,
          () => action.hitTestable().evaluate().isNotEmpty && !fixture.busy,
          'The original and its main actions must be reachable again.',
        );
        await tester.runAsync(() => tester.tap(action));
        await officePreviewUntil(
          tester,
          () => toolbar.hitTestable().evaluate().isNotEmpty && !fixture.busy,
          'Reopening the ink editor must reuse the already prepared PDF.',
        );
        expect(preview.calls, 1);
        expect(edit.calls, 0);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    }),
    skip: !officePreviewPdfiumAvailable,
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'a disk reload during Office conversion preserves the pending PDF and original',
    (tester) => _withFixture(tester, (fixture) async {
      final workspace = await officePreviewRead(
        tester,
        () async => WorkspaceController(fixture.repository),
      );
      final started = Completer<void>();
      final release = Completer<void>();
      final edit = _CountingEdit();
      final preview = _CountingPreview((path, id) async {
        started.complete();
        await release.future;
        return fixture.previewResult(path, id, PdfColors.red);
      });
      final button = find.byKey(const ValueKey('office-preview-pdf'));
      try {
        await _mount(tester, fixture, edit, preview);
        await officePreviewUntil(
          tester,
          () =>
              button.evaluate().isNotEmpty &&
              tester.widget<ButtonStyleButton>(button).onPressed != null,
          'The PDF annotation action must be available',
        );
        await tester.ensureVisible(button);
        await tester.runAsync(() => tester.tap(button));
        await officePreviewUntil(
          tester,
          () => started.isCompleted,
          'Office conversion must be awaiting its native result',
        );
        await officePreviewRead(tester, workspace.reloadFromDisk);
        await _mount(
          tester,
          fixture,
          edit,
          preview,
          repository: workspace.repository,
        );
        release.complete();
        await officePreviewUntil(
          tester,
          () => find.byType(Editor).evaluate().isNotEmpty && !fixture.busy,
          'The pending PDF must open in the annotation editor after resume',
        );
        final (edition, variants) = await officePreviewRead(tester, () async {
          final documents = OfficeDocumentStore(workspace.repository);
          final edition = await documents.readLatest(fixture.note);
          return (
            edition,
            await documents.readPdfVariants(fixture.note, edition),
          );
        });
        expect(edition.originalBytes, fixture.original);
        expect(variants.single.pdfSha256, preview.result!.pdfSha256);
        expect(preview.calls, 1);
        expect(edit.calls, 0);
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox());
        await officePreviewRead(tester, () async => workspace.dispose());
      }
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'parent save waits for a private preview and back returns without publishing it',
    (tester) => _withFixture(tester, (fixture) async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final before = await officePreviewRead(tester, fixture.revisionCount);
      final edit = _CountingEdit();
      final preview = _CountingPreview((path, id) async {
        entered.complete();
        await release.future;
        return fixture.previewResult(path, id, PdfColors.red);
      });
      var backs = 0, saveDone = false;
      Object? saveError;
      try {
        await _mount(tester, fixture, edit, preview, onBack: () => backs++);
        await _load(tester);
        await officePreviewUntil(
          tester,
          () => entered.isCompleted,
          'The private conversion must be running',
        );
        await tester.runAsync(() async {
          tester
              .state<OfficeWorkspaceState>(find.byType(OfficeWorkspace))
              .save()
              .then(
                (_) => saveDone = true,
                onError: (Object error) {
                  saveError = error;
                  saveDone = true;
                },
              );
        });
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          saveDone,
          false,
          reason: 'A parent close must await the in-flight private operation',
        );
        expect(backs, 0);
        release.complete();
        await officePreviewUntil(
          tester,
          () => saveDone,
          'The parent save must finish after the private result is retained',
        );
        expect(saveError, isNull);
        await _shown(tester, preview.result!.pdfSha256);
        final back = find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '문서 목록으로',
        );
        await officePreviewUntil(
          tester,
          () => tester.widget<IconButton>(back).onPressed != null,
          'The back action must be enabled after conversion',
        );
        await tester.runAsync(() async {
          await tester.tap(back);
        });
        await officePreviewUntil(
          tester,
          () => backs == 1,
          'Back must return to the document list',
        );
        expect(preview.calls, 1);
        expect(edit.calls, 0);
        expect(await officePreviewRead(tester, fixture.revisionCount), before);
        expect(await officePreviewRead(tester, fixture.inkRevisions), isEmpty);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    }),
    skip: !officePreviewPdfiumAvailable,
  );
}

class _PreviewFixture {
  new(this.directory, this.repository, this.note, this.original);
  final Directory directory;
  final NoteRepository repository;
  VaultNote note;
  final Uint8List original;
  var busy = true;
  OfficeDocumentStore get documents => OfficeDocumentStore(repository);

  static Future<_PreviewFixture> create({OfficeTemplateKind? template}) async {
    final directory = await Directory.systemTemp.createTemp(
      'office-original-workspace-',
    );
    NoteRepository? opened;
    try {
      await FileManager.init(
        documentsDirectory: '${directory.path}/documents',
        shouldWatchRootDirectory: false,
      );
      final repository = await NoteRepository.open(
        Directory('${directory.path}/vault'),
        createFormatVersion: 2,
      );
      opened = repository;
      final starter = template == null
          ? null
          : OfficeTemplates.create(template, title: 'Original preview');
      final original = starter?.bytes ?? annotationOfficeFile('original');
      final note = await OfficeDocumentStore(repository).importDocument(
        title: 'Original preview',
        fileName: starter?.fileName ?? 'original.docx',
        bytes: original,
      );
      return _PreviewFixture(directory, repository, note, original);
    } catch (_) {
      await opened?.close();
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<OfficeEdition> paired(PdfColor color) async => documents.commitEdited(
    await documents.beginEdit(note),
    originalBytes: original,
    pdfBytes: await officePreviewPdf(color),
    engineVersion: 'paired-fixture',
    pageCount: 1,
  );
  Future<int> revisionCount() async => (await repository.revisions()).length;
  Future<List<RevisionRecord>> inkRevisions() async =>
      (await repository.revisions())
          .where((record) => record.kind == EntityKind.ink)
          .toList();
  Future<RevisionRecord> currentSource() async =>
      (await repository.heads(note.sourceEntityId!)).single;
  Future<OfficePreviewResult> previewResult(
    String path,
    String id,
    PdfColor color,
  ) async {
    final bytes = await officePreviewPdf(color);
    final output = Directory('${directory.path}/private-preview/$id');
    await output.create(recursive: true);
    final pdf = await File('${output.path}/preview.pdf')
        .writeAsBytes(bytes, flush: true);
    return _OwnedPreviewResult(
      expectedBytes: bytes.asUnmodifiableView(),
      pdfPath: pdf.path,
      pdfSha256: sha256.convert(bytes).toString(),
      pageCount: 1,
      sourceSha256: sha256.convert(await File(path).readAsBytes()).toString(),
      engineVersion: 'private-preview-fixture',
    );
  }

  Future<void> close() async {
    await repository.close();
    await directory.delete(recursive: true);
  }
}

class _OwnedPreviewResult extends OfficePreviewResult {
  new({
    required this.expectedBytes,
    required super.pdfPath,
    required super.pdfSha256,
    required super.pageCount,
    required super.sourceSha256,
    required super.engineVersion,
  });
  final Uint8List expectedBytes;
  var disposalCalls = 0;

  @override
  Future<void> dispose() async {
    disposalCalls++;
    final output = File(pdfPath);
    if (output.existsSync()) await output.delete();
  }
}

class _CountingEdit extends FixtureOfficeEngine {
  var calls = 0;
  @override
  Future<AndroidOfficeEditResult> edit({
    required String sourcePath,
    required String sessionId,
  }) {
    calls++;
    throw StateError('Read-only original preview must not open the editor');
  }
}

class _CountingPreview extends OfficePreviewEngine {
  new(this.run);
  final Future<OfficePreviewResult?> Function(String, String) run;
  var calls = 0;
  OfficePreviewResult? result;
  @override
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) async {
    calls++;
    return result = await run(sourcePath, sessionId);
  }
}
